# .NET 10 IL generator: design

Date: 2026-10-21
Status: ready for review by the person driving this

## Intent

hxc accepts `--cs` today and writes nothing. This adds a backend that compiles Haxe straight to a
.NET 10 assembly (IL + metadata in a PE file) with a Portable PDB beside it. It replaces Haxe 4.3.7's
gencs + hxcs pipeline, which writes C# source that `dotnet build` then compiles.

The first and driving user is **the server app** (`<server-app>`). Its server
business logic is Haxe (`cs.HaxeRecordServer`, about 567 generated C# files, ~486k lines today) and
is consumed by an ASP.NET Core 10 host (`cs/Server`) through the `cs/HaxeServer` project.

### Why

The server app's current pipeline only works because of workarounds for gencs/hxcs limits. A recon of the
project (read-only) found:

- **Text patches after every build**, in `haxe/src-yml/Builder.hx` (lines ~238-252):
  - deleting `haxe/lang/BoxedPointer.cs` and `cs/Pointer.cs` (unsafe leftovers that aren't used);
  - rewriting an invalid generic cast in `thx/Options.cs`:
    `return ((global::Array<T>) (new global::Array<object>(new object[]{})) );`;
  - injecting `#nullable enable` into every `ai.tools` namespace file so Semantic Kernel describes
    `string` parameters as non-null in the AI tool JSON schemas (see the comment above
    `Search_Filter` in `haxe/src-ai/ai/tools/ReportSearch.hx`).
- **A runtime override**: `haxe/src/cs/internal/FieldLookup.hx` replaces hxcs's global field table,
  which was not thread-safe under concurrent reads and writes (server app issue #6551).
- **Inline C#** (`untyped __cs__`, ~25 uses but only 4 patterns): rethrow keeping the stack trace
  (~20), a multi-dimensional indexer `cells[row, col]` on EPPlus (2), a decimal literal
  `(decimal){0}` (1), a `#pragma warning disable` through `@:classCode` (1).

The person driving this asked whether IL would be faster and easier to debug. The conclusions they
accepted:

- Runtime speed comes from how Haxe concepts are represented (generics, `Dynamic`, enums,
  closures), not from C# vs IL. RyuJIT optimizes either way.
- Builds get faster: hxc writes the DLL itself, so there's no `dotnet build` of generated sources.
- Debugging gets better for users, as long as a Portable PDB maps IL to `.hx` lines.
- No hand-editing of generated C# happens today (the server app's CLAUDE.md forbids it), so losing
  editable C# output costs nothing.

**Decided: IL + Portable PDB. No C# source output.**

## Success

The acceptance test belongs to the person driving this, in their words: *migrate a test database to
new generated code without issue.*

The server app stores records in MySQL as Haxe-serialized strings. On load, the server upgrades old records
and re-saves them in the current shape. Success means:

1. A server app built with the new generator opens an existing test database, runs its normal
   upgrade path, and every record loads, migrates and saves with nothing lost or silently changed.
2. **Two-way compatibility (hard requirement):** data written by the new server must be readable by
   today's gencs-built server, and the reverse. Rollback and side-by-side running must work without
   converting data.

The suggested proof is a differential run: the same migration on two copies of the test DB, one per
build, then diff the results. Any difference is a bug in the new generator until shown otherwise.

**Acceptance environment:** a test database copy, MySQL, and the ability to run both the server app builds
will be available to the builder *eventually*, not from the start. Until then the plan needs a
stand-in that milestone 3 can test against: a corpus of serialized values covering every type and
encoding the Compatibility section lists, round-tripped through both runtimes in both directions.
Once the real environment arrives, records pulled from the test database join the corpus, and
milestone 6 runs the real migration.

**One source tree** (preferred): after the switch, the server app's source should still build with Haxe
4.3.7 gencs, so rollback and the differential run use the same code. Anything dotnet-only in the server app
goes behind `#if dotnet`. The inline-C# subset below exists partly so the server app's existing `__cs__` uses
need no change at all. "Today's gencs-built server" for the two-way test means the same server app
commit built with Haxe 4.3.7.

## Goals

- `HaxeServer.dll` + `HaxeServer.pdb` produced directly by hxc and referenced by `cs/Server` in place
  of the `HaxeServer.csproj` compile.
- Runtime behavior that matches hxcs wherever data or the C# side can observe it (see
  Compatibility).
- Native .NET interop at least as good as gencs: `--net-lib`/`--net-std` assemblies, `@:nativeGen`,
  `@:strict(...)` attributes, `@:property`, `@:native`, delegates, events, overloads, real generics.
- Debugging in the user's `.hx` files: breakpoints, stepping, locals by their Haxe names, and `.hx`
  file:line in exception stack traces when the PDB is deployed.
- Every one of the server app's Builder.hx patches becomes unnecessary.
- The FieldLookup thread-safety fix carries over (or the new runtime is thread-safe by design).

## Non-goals

- Byte-identical output with Haxe 4.3.7's gencs (C# source). This target is new; hxc's "identical
  output" promise does not apply to it.
- C# source output, in any mode.
- .NET Framework, Mono, or .NET before 10. .NET 10 (`net10.0`) is targeted by default, and
  `-D dotnet-version=<N>` picks a later one (see Output).
- Edit and Continue / Hot Reload.
- NativeAOT-specific work (emitted IL should not rule it out, but nobody tests for it).
- Changes to the server app's JS client or Electron builds.
- A performance target. There is no compile-time or runtime budget versus today's pipeline, so no
  benchmark gates any milestone. Fixing an obvious, large regression found along the way is still
  in scope.

## Anti-goals

- Any change in serialized data, class/enum names written into data, or reflection results that
  breaks the two-way compatibility above, even if the new behavior is "more correct".
- A generator that needs post-build text patching to produce a working assembly.
- Silent miscompiles: invalid IL must be caught at build/test time, not by a customer.

## Constraints

- **hxc is written in Haxe and runs as a native binary** (hxcpp). The PE, metadata, IL and PDB writers
  and the assembly reader must be Haxe code inside hxc. `System.Reflection.Metadata` is not available.
- **Follow the JVM backend's shape** (`src/hxc/codegen/jvm/`, ~7k lines). It solves the matching
  problems: constant pool ≈ metadata tables/heaps, signatures ≈ blob signatures, `.class` writer ≈
  PE writer, `--java-lib` reader (`src/hxc/codegen/java/`) ≈ `--net-lib` reader. .NET has no
  StackMapTable; IL needs `maxstack`, consistent stack depth at merge points, and an empty stack when
  entering a `try`.
- **Deterministic output**: same inputs give byte-identical DLL and PDB (hxc has a determinism test
  family under `tests/cases/determinism`). Use a content-derived MVID and PDB id.
- **Match the surrounding code**: hxc's naming, comment density and idiom.
- **Reference assemblies**: the server app compiles against `haxe/res/netcore-dlls/` (5 project DLLs plus
  `net-40/` with 63 framework and package DLLs: `System.Runtime.dll`, `mscorlib.dll`, NHibernate,
  Semantic Kernel, Microsoft.Extensions.AI, EPPlus.Core, …). The reader must handle type forwarding
  between them (`mscorlib`/`netstandard` → `System.Runtime` → `System.Private.CoreLib`).
- **Reference drift is now a runtime risk.** That folder has drifted from what `cs/Server` ships:
  Semantic Kernel 1.72 vs 1.81 deployed, NHibernate 5.2 vs 5.7, and a .NET 5-era `System.Runtime.dll`.
  gencs output was recompiled by `dotnet build` against the real packages, which absorbed the drift.
  IL member references are fixed when hxc writes them, so a member that changed between versions
  becomes a `MissingMethodException` at runtime. *(My call:)* hxc compiles against whatever
  `--net-lib`/`--net-std` name, the same as today. The one exception is inline C#'s member lookup: when no
  `--net-std` class along the chain declares the name, it falls back to the reference pack, because inline
  C# is written against the net10 surface the pack describes (gencs's C# is compiled against it). The
  acceptance setup adds an ILVerify run of
  `HaxeServer.dll` with the **deployed** assemblies as references, which reports any member
  reference that doesn't resolve. The server app refreshes `res/netcore-dlls/` from its build outputs, which
  its own CLAUDE.md already asks for whenever the C# projects change.

## Compatibility (what must match hxcs)

Two parties can observe the output: stored data (and the JS client, which talks Haxe serialization
to the server), and the hand-written C# in `cs/Server`, `cs/SharedServer`, etc. Whatever either one
can see must behave like Haxe 4.3.7 gencs + hxcs:

- `haxe.Serializer` / `haxe.Unserializer` output and input, byte for byte. This includes class and
  enum names as `Type.getClassName` / `Type.getEnumName` report them, enum constructor names and
  indices, field order where it affects output, and how `Int`, `Float`, `null`, `Date`, `Bytes`,
  `haxe.ds.*Map`, `List` and anonymous structures encode.
- Reflection: `Reflect.field`/`setField`/`fields`, `Type.resolveClass`, `Type.getInstanceFields`,
  `Type.createEmptyInstance`, dynamic field access on class instances and anonymous objects.
- Number and date semantics: 32-bit `Int` overflow, `Float`→`Int` conversion, `Std.parseInt` /
  `parseFloat`, `Date` time zone behavior, string formatting of floats.
- **CLR names the C# side uses**: namespaces, type names, member names, generic arity and the
  runtime entry points it calls today, e.g. `haxe.lang.Runtime.setField(obj, "name", 0, value)` in
  `cs/Server/Controllers/RecordController.cs`, and `Serializer.run` / `Unserializer.run` plus Haxe
  classes such as `ReportingTools` and `CultureManager` in `cs/SharedServer/ServerManager.cs`. A
  repo-wide grep of `cs/` for Haxe-generated names gives the full list; that list is the interop
  surface to keep.
- Core type mapping, as gencs does it (confirm against Haxe 4.3.7's gencs and `std/cs`): `Int`→`int`,
  `Float`→`double`, `Bool`→`bool`, `String`→`string`, `Dynamic`→`object`, `Null<T>` of a value type
  as `haxe.lang.Null<T>`, enums as classes deriving from the hxcs enum base. `Array<T>` and every
  other Haxe generic class is a real generic class whose non-basic type arguments are erased to
  `object` (`Array<C>` is ``Array`1<object>``), and an `X<Dynamic>` is typed as the class's companion
  interface (`Array`). The next section has the rules.

Where hxcs behavior is a bug that data depends on, reproduce it. Write each such case down as a known
divergence from "correct" behavior. This generator fixes two hxcs bugs on purpose: Haxe issue 8314,
and the parent casts that always return `this` (next section). The fixes are shaped so serialized data
doesn't change, with two exceptions, both from the #8314 forward (*Recorded divergences*, item 1): the
Serializer's cache writes an array and its forward once, the second as a back-reference `r` where gencs
writes the array again, and a write past `length` through a forward fills the gap with the target type's
default, which serializes as `z` where gencs writes `u`. The next section also lists the few paths where
gencs throws and hxc works.

## Casts between generic instantiations (Haxe issue 8314)

**What hxcs does.** gencs gives a Haxe generic class real CLR type arguments only when they are
"basic": `Int`, `Float`, `Bool`, `UInt`, `Single`, `Int64` and the other `cs` integers, `String`,
abstracts over these, and .NET value types and enums. It erases every other argument to `object`:
classes, interfaces, Haxe enums, anonymous structures, function types, `Any`, `Null<X>` of anything
but `String`, and every generic instantiation. `Array<C>`, `Array<Null<Int>>`, `Array<Array<Int>>`,
`Map<String,C>` and `List<C>` are all ``…`1<object>``, at every nesting level. An argument that is
`Dynamic` (also through a typedef or `Null<>`), or an unbound monomorph (gencs's `has_tdyn`), makes the
static type the **companion interface** of
the class (`global::Array`, `global::haxe.ds.StringMap`), and the `new` builds the ``<object>``
instantiation. `Type.resolveClass("G")` and a class constant `G` give ``typeof(G`1<object>)``, found
through the interface's `GenericInterface` attribute.

A value's static type and its object's instantiation can still disagree. `haxe.Json.parse` and
`haxe.Unserializer` build every array, map and generic object with `<object>`. When such a value
flows into a typed slot, gencs's `RealTypeParams` filter calls `__hx_cast`. That returns `this` when
the type arguments match; otherwise it builds a new object and copies the fields into it, converting
native arrays element by element with `Runtime.genericCast`. Erasure decides which slots match:

- A slot of `Array<C>`, `Map<String,C>`, `G<Null<Int>>` or `Array<Array<Int>>` is ``<object>``, so
  the cast is the identity. Unserialized data shares storage with such a field and writes persist.
- A slot with a basic argument (`Array<Int>`, `Array<String>`, `StringMap<Int>`, `G<Float>`) gets a
  copy. So every read of an anonymous-structure field typed `Array<Float>` that holds an unserialized
  array returns a fresh copy, and writes through it are lost
  ([HaxeFoundation/haxe#8314](https://github.com/HaxeFoundation/haxe/issues/8314), closed in favor of
  [#4872](https://github.com/HaxeFoundation/haxe/issues/4872), which the Haxe team said won't be fixed
  for C#).
- In nested arrays the outer array is ``Array`1<object>`` and never converts. Each inner array is
  cast when an element is read, so `h.aai[0][0] = 5` is lost.

The other direction does not copy. A typed value passed to an `X<Dynamic>` slot is an upcast to the
companion interface: the same object, so `ad == ai` holds and the callee's writes reach the caller.
Members that mention a type parameter then go through `Runtime.callField`, which is why a wrong-typed
write through it converts or throws inside the typed storage.

The copy itself has details that data can see. `genericCast` into `Int` goes through
`IConvertible.ToInt32`, which rounds half to even (`0.5` → `0`, `1.5` → `2`, `2.5` → `2`) and
converts numeric strings (`"7"` → `7`) and `Bool`s, throws `FormatException` for other strings
(`"1.5"`, `"ab"`), `OverflowException` for `NaN` and values out of range, and `NullReferenceException`
for an object, a `Date` or an enum value; into `Int64` it truncates. A `null` element is skipped and
stays `default(T)` (`0`, `0.0`, `false`). The map and `List` copy has a bug: `hashes`,
`_keys` and `flags` are shared with the original, so a `set` through the copy makes its key appear in
the original with a `null` value, and serializing the original then writes it. A `List` copies its
node chain twice, so an `add` on the copy is lost from both. gencs also skips the cast in two places
and throws instead: `return d` of a `Dynamic` as `Array<Int>` is a plain C# cast, and a closure call
goes through reflection. Finally, every parent cast on a generic class (one for each generic
interface it implements and one for its generic superclass) returns `this`, so a cast to another
instantiation of a generic interface throws (see *Parent casts* below).

The server app works around #8314. `haxe/src-shared/models/ClassNameMacro.hx` generates a `scrubArrays` for
each data typedef that reads every top-level array field and writes it back; `DataSource_Json`,
`DataSourceDBCache` and `RecordServer`'s undo/redo call it. Nested arrays and values from
`Unserializer.run` aren't covered.

**Decided: hxc adopts gencs's typing and casts, and fixes #8314 for `Array`.**

*Typing.* hxc erases and types as gencs does. The rest depends on it: without erasure every
class-typed array and map would need a cast, and `StringMap<C>` fields read from data would start
losing writes that gencs keeps.

- **Erasure.** Every non-basic type argument is `object`, in fields, locals, parameters, returns,
  `new` and method instantiations. Type parameters stay. A generic class whose fields mention a
  non-Haxe-generic generic type over its type parameters (`var l:List_1<T>`) is a "native generic",
  like `@:nativeGen`: it keeps its real type arguments, has no companion and no casts, and
  `Type.resolveClass` gives `null` for it. hxc runs gencs's scan for this.
  An unbound monomorph argument counts as `Dynamic`, as gencs's `has_tdyn` has it, which reflection
  sees in field and signature types: a field `var arr = []` is of type `Array`, the companion, and
  `Std.downcast(d, Box)` is `d as global::Box`.
- **Companion interfaces.** Each generic Haxe class and interface `pack.X<T…>` gets a non-generic
  interface `pack.X` (no arity), carrying `haxe.lang.GenericInterface(typeof(X<object…>))` and the
  base interfaces `haxe.lang.IHxObject` and `haxe.lang.IGenericObject`. It declares `X_cast<T_c>()`,
  the casts of the generic interfaces it implements and of its superclass, and every kept instance
  method whose Haxe signature mentions no type parameter, in gencs's order and spelling. A generic
  interface's static `__hx_cast` helper lives in `X__Statics_`. Cast methods are named
  `<flatpath>_cast`, the helper `__hx_cast<T_c_c…>`. A generic `@:struct` gets no companion, and the
  casts of its generic interfaces return `this`: gencs's C# for one (`struct Cell<T> :
  haxe.lang.HxObject`) doesn't compile, so there is nothing to match.
- **`X<Dynamic>` is the companion.** A typed value assigned or passed to it is the same object, with
  no view and no copy. Member access through it follows gencs: members that don't mention a type
  parameter are interface calls, the rest go through `Runtime.getField`/`setField`/`callField`.
- **Casts are gencs's.** `X_cast` and `__hx_cast` are emitted as gencs does. A cast between typed
  instantiations still copies, and so does a second reinterpretation of an array to a different type.
  The map and `List` copy keeps its shared `hashes`/`_keys` and its lost `add`, because stored data
  depends on it. A `Map` abstract's downcast to its specialization with the same type arguments (the
  commonest shape in the server app) is the identity cast it is in gencs. `Type.resolveClass` of a generic
  class returns ``typeof(X<object…>)``.
- **Indexers are gencs's.** gencs gives every class with an instance `__get` and/or `__set` (Array
  included) an indexer, `T this[int]` on ``Array`1``, and a class with a companion and array access also
  the companion's `object this[int]`, implemented explicitly (milestone 4b; `array-indexer-clr-surface`).
  An interface's indexer is a default interface member, which an implementing class's own indexer
  implements (`haxe-interface-indexer`). Known limit: a generic interface whose `__get` mentions no type
  parameter gets no `Item` property (CLR surface only; Haxe rejects `i[x]` on an interface).
  Element access on an `Array<Dynamic>` reads, writes and increments through the companion's indexer,
  whose setter casts with `(T)value`: `a[1] = 3.7` on an `Array<Dynamic>` holding an `Array<Int>`
  throws `InvalidCastException`, and `++` stores a double, which throws there too. `op=` goes through
  `Runtime.callField` `"__get"`/`"__set"`, which convert, as gencs's DynamicOperators writes it
  (`array-companion-element-access`, `array-companion-increment`).

*Parent casts.* gencs's `P_cast<…>() { return this.X_cast<own params>(); }` always returns `this`.
`FallbackPromise<T> implements Thenable<T>` shows it. Given a `FallbackPromise<Dynamic>` in a
`Dynamic`, a cast to `Thenable<Int>` calls `Thenable_cast<Int>()`, which runs
`FallbackPromise_cast<T>()` with the object's own `T`, so it returns the object unchanged and the
`castclass` after it throws `InvalidCastException`. The superclass case is the same code: `GSub<U>
extends G<U>` throws on a cast to `G<Int>`, and so do the standard library's `StringMap` and
`ObjectMap` casts to `IMap`. hxc emits the correct body, for interfaces and superclasses alike. The
rule: take the parent as the class declares it, written in the class's type parameters after
erasure, `P<a1…am>`. The body of `P_cast<P1_c…Pm_c>()` is `return this.X_cast<b1…bn>()`, where for
each class parameter `Tk`, `bk` is `Pj_c` for the first `j` with `aj = Tk`, and `Tk` itself when no
`aj` is `Tk`. So `Thenable_cast<T_c>()` calls `FallbackPromise_cast<T_c>()`, and `Perm<X,Y>
implements I2<Y,X>` calls `Perm_cast<B_c, A_c>()`. When two `Pj_c` for one `Tk` would differ
(`Both<T> implements I2<T,T>` cast to `I2<Int,String>`), no instance can satisfy the cast and the
`castclass` throws, as gencs's does. When the parent doesn't mention a class parameter `Tk`
(`Fixed<T> implements I1<Int>`), `Tk` stays itself, so the body is still `this.Fixed_cast<T>()` and
the cast returns `this`, as gencs's does. A class that is not generic and lists the interface itself
keeps gencs's cast that returns `this`, so a cast to another instantiation throws, as gencs's does; one
that only inherits a generic superclass's cast (`class NS extends GB<String>`, `GB<T> implements IG<T>`)
gets the superclass's copy, a `GB<X>`, not an `NS`. This is a deliberate divergence like #8314.

*The #8314 forward.* The design is the one Nicolas Cannasse described in #4872, which HashLink
implements (`hl.types.ArrayDyn`): an ``Array`1<object>`` is untyped until its first cast to a typed
instantiation locks it, and from then on every reference shares one storage.

- **Only ``Array`1<object>`` forwards, and only to a basic-element array.** hxc's runtime copy of
  `Array.hx` gets one field: the typed array this one stands for. Any cast of a non-forwarding
  ``Array`1<object>`` to an `Array` of `String` or a value type tries it, whatever the static source
  of the value: a `Dynamic`, a type parameter, an anonymous field read, or a typed ``Array`1<object>``
  such as an `Array<Null<Int>>`. It forwards when every element survives the conversion (*Only
  lossless conversions* below), and only `Int`, `Float`, `Bool`, `String`, `Single` and `Int64`
  elements convert (`Array.hx`'s `__hx_lossless`). Into `UInt` and the small integer types (`Int8`,
  `Int16`, `UInt8`, `UInt16`) nothing converts: the cast forwards only when every element already has
  that CLR type, which unserialized data never gives, and otherwise copies.
  A typed instantiation (``Array`1<int32>``, ``Array`1<string>``, …) never forwards. A typed array
  held in an `Array<Dynamic>` slot is an upcast and needs nothing.
- **Reinterpret once.** The cast converts the elements into a new `Array<X>`, installs it as the
  forward target, and returns it. The check, the conversion and the install all run under
  `Monitor.Enter(this)`/`Exit(this)`, behind a second look for a forward, since hxc has no `ref`
  arguments for `Interlocked.CompareExchange`. A thread that loses the race returns the winner's array
  (and never scans the old storage, which pushes through the winner's target have outgrown). The old
  storage stays in place, so a reader that raced the install sees the same values. Later casts of the
  object to `Array<X>` return that same array: `t.val == t.val` holds, and a write through either
  reference shows through the other. Writers racing the install are not covered: that is concurrent
  mutation of an unsynchronized `Array`, which hxcs doesn't make safe either.
- **Only lossless conversions.** An element converts when its value survives: an `Int`, or a `Float`
  holding an `Int` value, into `Array<Int>` (`-0.0` too: `genericCast` gives `0` and the Serializer
  writes `z` for both); any number into `Array<Float>`; a `Bool` into `Array<Bool>`; a string or
  `null` into `Array<String>`; a value that round-trips into `Array<Single>` or `Array<Int64>`.
  Erasure leaves `String` as the only reference element type, so the list ends there. If any element
  doesn't convert, the cast does what `__hx_cast` does: it copies, or throws where `genericCast`
  throws. A stored `1.5` in an `Array<Int>` field, or a `null` in an `Array<Float>`, is never
  rewritten just because code read it, so serialized data stays what hxcs writes. (`Type.typeof`
  reports an `Int`-valued `Float` as `TInt`, so `Serializer` writes `1` and `1.0` the same way.)
- **A wrong-typed write converts.** A write through a forwarder lands in the typed storage, so it
  converts as `genericCast` does (`2.5` becomes `2` in an `Array<Int>`, by rounding) or throws where
  that throws. Under hxcs the same write would have gone into an untyped copy. Typed code sees this
  too, because erasure makes `Array<Null<Int>>`, `Array<C>` and `Array<Array<Int>>` all
  ``Array`1<object>``: an `Array<Null<Int>>` view of a reinterpreted array turns `push(null)` into
  `0`. A write past `length` fills the gap with the target type's default (`0`, `false`), not `null`,
  so the record serializes `z` where hxcs writes `u`: `d[4] = 7` on `{"val":[1,2]}` read as
  `Array<Int>` gives `ai1i2zzi7h` against gencs's `ai1i2u2i7h`.
- **Converted elements take the target's type.** They keep their value but not their CLR type, and
  `indexOf`/`lastIndexOf` (`System.Array.IndexOf`, which compares with `Equals`) see it: on `[2.0, 3]`
  from Json, once `Array<Int>` reinterprets it, `indexOf(2.0)` goes from `0` to `-1` and `indexOf(2)`
  from `-1` to `0`. `contains` and `remove` compare with `Runtime.eq` and are unchanged.
- **Nested arrays.** The outer array is ``Array`1<object>`` and never converts. Each inner array
  converts when an element read casts it, as above, so `h.aai[0][0] = 5` persists where gencs loses
  it.
- **`length` is a field kept in sync.** hxc can't emit CLR properties yet, and a field keeps C# that
  reads `.length` compiling. A reinterpreted target keeps a back-reference `__hx_from` to its
  forwarder and writes `__hx_from.length` wherever it writes its own `length`.
- **Everything that reaches storage resolves the forward first**: every `Array` member, including
  the ones hxcs inlines into callers (`map`, `filter`, `iterator`, `__unsafe_get`, …), and the dynamic
  paths in `cs.internal.Runtime`. The std readers of `__a` (`cs.Lib.nativeArray`, `haxe.Rest`)
  resolve it too. `Reflect.field(a, "__a")` on a forwarder returns the stale storage, as gencs's
  untyped original would.
- **Equality sees one array.** `Runtime.eq` and `refEq`, `==` with an `Array<Dynamic>`, `Dynamic` or
  type-parameter operand, `==` between an ``Array`1<object>`` (`Array<Null<Int>>`, `Array<Any>`) and
  an `Array` of a basic element (which gencs's C# can't compile, CS0019), and `Equals`/`GetHashCode`
  overrides on `Array` compare forward targets. That keeps `indexOf`/`lastIndexOf` (which use
  `System.Array.IndexOf`), `remove`/`contains` (which use `Runtime.eq`) and `ObjectMap` keys
  consistent. `GetHashCode` is the forwarder's identity hash, for the forwarder and its target alike,
  so an array already used as a key keeps its hash when it is reinterpreted. An array that neither
  forwards nor is a forward target keeps reference identity. The overrides call methods Haxe code
  doesn't see, so `Array` has no `Equals` or `GetHashCode` field, as in gencs; they are neither
  reflected nor members of the `Array` companion interface, which stays gencs's.
- **Unchanged from hxcs:** maps, `List` and other generic classes keep `__hx_cast`'s copy, bugs
  included. A search of the server app found no map read from serialized data with a basic value type, and no
  generic class of its own besides `CSTools.IEnumerableIterator`. It also depends on
  `amf3haxe.mx.collections.ArrayCollection<T>` and promhx's `Promise`, `Stream`, `Deferred` and
  `AsyncBase<T>`; all of them are same-instantiation under gencs. If a map with a basic value type
  turns up in data, extend the forward to the `haxe.ds` maps.
- **The C# side keeps working.** `Array` stays a real generic class (`cs/SharedServer/Importer.cs`
  builds `new Array<string>()` and reads `.length`), `Array<String>` stays ``Array`1<string>``, an
  `Array` of a typedef stays ``Array`1<object>``, and `Unserializer.run` still returns an
  ``Array`1<object>`` (`cs/SharedServer/ServerManager.cs` casts it to one).

*Recorded divergences.* The differential suite records each of these as a deliberate divergence from
hxcs, with gencs's output kept for contrast:

1. **The #8314 forward**: a cast of an ``Array`1<object>`` to a basic-element `Array` shares storage
   instead of copying, and writes through it convert. A write past `length` through it fills the gap
   with the target type's default instead of `null`, and converted elements take the target's CLR type,
   which `indexOf`/`lastIndexOf` observe (cases `cast-array-dynamic-write`, `cast-array-forward-storage`).
   Everything that compares through `Runtime.eq`, `Runtime.refEq` or `Equals` sees an array and its
   forward as one array where gencs sees two: `==` and `!=`, `indexOf`/`lastIndexOf`/`contains`/
   `remove`, `ObjectMap` keys, `Reflect.compareMethods(a.join, b.join)`, `Type.enumEq(W(a), W(b))`, and
   `Equals` on two `haxe.lang.Closure`s of the pair as C# sees them, all true where gencs gives false
   (cases `cast-4872-eq`, `cast-array-forward-eq`). The Serializer's cache (`useCache = true`) finds the
   pair through `==` too, so it writes the second as a back-reference `r` where gencs writes the array
   again, and read back the two share storage (case `cast-array-forward-storage`).
2. **Parent casts** return the right instantiation instead of `this`, so casts that throw in gencs
   work.
3. **Paths where gencs throws but this design works are left working**:
   - `return d` of a `Dynamic` as `Array<Int>`, which skips `__hx_cast` in gencs;
   - closure calls with an array argument that needs a cast;
   - `Type.createInstance` of a class with one constructor (`@:nativeGen`) given an argument that is
     another instantiation of the parameter's generic type: `Runtime.callMethod` casts it with
     `__hx_cast`, where gencs's reflection invoke throws `ArgumentException`. A Haxe class has a second,
     `EmptyObject` constructor, so the call filters by assignability first and both throw the same
     `String` (case `create-instance-generic-argument`);
   - `map` and `filter` on a typed array held as `Array<Dynamic>` (gencs's inlined loops cast `__a`
     to `object[]`, which fails for an `int[]`);
   - an `Array<Int>` passed as `Array<Any>` (a C# compile error in gencs);
   - a method of an erased generic interface (`IQ<C>` is ``IQ`1<object>``) implemented by an
     inherited method: gencs's overload `object f(object x) { return this.f((C) x); }` calls itself
     until the stack overflows, hxc's calls the inherited method (case
     `erased-interface-inherited-implementation`);
   - `class Q implements I<Dynamic>` returning `Array<Dynamic>` for `I`'s `Array<T>` (a C# compile
     error in gencs, CS0738; case `erased-interface-dynamic-argument`);
   - an abstract generic class's own cast, which a subclass that is not generic inherits: gencs's body
     `return this.X_cast<T…>()` calls itself until the stack overflows, hxc's returns `this` for the
     object's own type arguments and throws `InvalidCastException` for others (case
     `struct-and-abstract-base-casts`).

*Reproduced hxcs bugs.* These stay, because data depends on them: the map and `List` copy that shares
`hashes`/`_keys` and gives the original a `k => null`; `getResponseHeaderValues` throwing a
`NullReferenceException`; the Unserializer's `ArgumentException` on enum constructor arguments of
array or map type; and Json printing `"Box_cast":null`.

The server app's `scrubArrays` behaves the same under both generators, so it can stay. Writes no longer depend
on it, but it also turns a `null` array into `[]`, so removing it is the server app's call. Milestone 2
rejects these casts (a compile error in user code). Milestone 3 implements them, with cases for
#8314's example, the `haxe.Json` example from its comments, #4872's `a == b` test, type-argument
erasure and the companion interfaces, the parent casts (`FallbackPromise`, `GSub`, `IMap`), the
lossless fallback (data with `1.5` in an `Array<Int>` field re-serializes to the same string), a
wrong-typed write through `Dynamic` and through an `Array<Null<Int>>` view, nested arrays, the map
and `List` copy, and two threads casting one array at once.

## How it gets made (decided)

- **Output**: one PE32 IL-only, AnyCPU assembly per compile, plus a separate Portable PDB. Library
  output when there's no `-main`, a console app (with a `*.runtimeconfig.json`) when there is.
  The runtimeconfig asks for `net10.0` unless `-D dotnet-version=<N>` names another .NET: a whole
  number, 10 or more, so `11` writes `net11.0` / `11.0.0`; anything else is a compile error. Only the
  runtimeconfig changes; the assembly's references come from `--net-std`/`--net-lib` as before.
- **Trimming**: `-D dotnet-trim-root` embeds the manifest resource `ILLink.Descriptors.xml`, which keeps
  every member of the assembly under `PublishTrimmed`, because the runtime's reflection reaches Haxe
  members by name. ILLink strips the resource from its output. Opt-in, because an untrimmed run's
  `GetManifestResourceNames` lists it where gencs's assembly has only `src.Resources.*` names. It does not
  keep .NET library members that only dynamic access reaches. Measured on 2026-10-29: fully trimming the
  server app's DLL as well would save at most 1.7 MB of a 141 MB self-contained publish, and removes code
  reached by name, so resolving the runtime's dynamic access for the trimmer was not taken up.
- **Command line**: `--cs <dir>` together with `-D dotnet` selects this generator, the same way
  `--java <dir> -D jvm` selects the JVM backend. The platform stays `cs`, so `#if cs`, the `cs.*`
  std package and every existing `cs.system.*` / `cs.NativeArray` / `@:nativeGen` use in the server app keep
  working. *(The define's name is my call.)* `--cs` without `-D dotnet` keeps today's behavior.
- **Assembly name**: from the output directory's last segment unless `-D dll-name=<name>` sets it,
  so the server app gets `HaxeServer.dll`. *(My call.)*
- **Runtime**: written in Haxe and compiled by the same generator into the output assembly, as hxcs
  does with `std/cs/internal/*.hx` (~1,800 lines in Haxe 4.3.7, ~100 of them inline C#). hxc ships its
  own copy of that runtime with the inline C# replaced by intrinsics, plus its own `cs/_std/Array.hx`
  for the forwarding in *Casts between generic instantiations*, and folds in the server app's FieldLookup
  fix. *(My call:)* overriding runtime internals through the classpath is not supported.
  The server app wraps its `cs/internal/FieldLookup.hx` override in `#if !dotnet`, keeping it for the gencs
  build, so hxc's runtime is free to change its internal API.
- **Inline C# (`__cs__`, `cs.Syntax.code`, `@:functionCode`, `@:classCode`)** *(my call)*: hxc parses
  a subset of C# **expressions** and compiles them with C#'s semantics. Anything outside the subset is a
  lasting compile error that names the replacement. Like gencs, hxc only checks inline code that survives
  DCE. The subset is what real code uses: one C# expression, or a bare `throw`.
  - `{N}` placeholders. A placeholder used twice evaluates its argument twice, as gencs's text substitution
    does.
  - `this`, simple names, dotted and `global::` names.
  - Keyword types (`bool` … `object`), array types `T[]` and generic type names, as cast and `is` targets,
    `new` targets and static receivers.
  - Member access (fields, properties, enum members, constants), calls, indexers with any number of
    arguments (`cells[row, col]`), and `new T(args)`.
  - Casts (chained, and as a parenthesised receiver: `(decimal){0}`, `(System.Char)ch`), `is`.
  - Unary `!` and `-`; binary arithmetic, comparisons, `==`/`!=`, `&&` and `||`, with C#'s numeric
    promotion. `==`/`!=` on references calls a user-defined operator that applies, found on either operand's
    class as C# looks it up (`System.Version`'s), and compares by identity where none does; it is refused where
    more than one applies or hxc cannot tell (`inline-cs-user-equality-operator`). A Haxe `null` of a
    reference type or `Dynamic` as a placeholder's argument is the C# null literal, as gencs's text
    substitution writes it; one of a `Null<T>` of a value type or of a type parameter is typed, as gencs's
    `default(global::haxe.lang.Null<int>)` and `default(T)` are (`inline-cs-null-placeholder`).
  - Literals: integer, real (`d`, `f`, `m`), string, char, `true`, `false` and `null`.
  - A bare `throw`, as `throw` or `throw;`, which emits IL `rethrow` and keeps the stack trace.
  - Everything else is a lasting error naming the replacement: assignment, lambdas, `typeof`, `as`, `?:`,
    `ref`/`out`, statements, `throw <value>`, explicit type arguments, array creation, `default`, `?.`,
    `??`, interpolated strings, a `{N}` inside a string literal, and the like.
  - `cs.Syntax.plainCode` is parsed the same way, with no placeholders.

  Names. The names the C# text gives are resolved in the Haxe scope, in the typer (`CsLift`), as C#'s
  simple-name lookup takes them: a simple name in head position that is a Haxe local, `this`, or a member
  of the current class chain becomes a placeholder whose argument is its typed expression. A `this.`-chain
  or member chain over non-extern Haxe fields is lifted whole, under `@:privateAccess` (haxe-strings'
  `this.sb.b`), and a Haxe method the text calls is called directly. A member of a .NET superclass is
  reached through a lifted `this`. Inlining, loop unrolling, closure capture, boxing and DCE then see
  ordinary expressions. Type names are not lifted: C# resolves them as CLR names, in the enclosing
  namespaces and then the global one, over the referenced assemblies and the reference pack. A member the
  `--net-std` lacks (hxcs's net-20 `StringBuilder` has no `Clear`) is looked up in the reference pack,
  which gencs's C# is compiled against. Known limits:
  - A member of a .NET superclass that the Haxe extern does not declare, named by its simple name, is
    C# error CS0103; `this.Name` reaches it.
  - A Haxe property read through a getter (`var x(get, never)`) is no C# member in gencs's output, so it is
    C# error CS0103 by its simple name and CS1061 through a value (`this.x`, `{0}.x`), as in gencs
    (`inline-cs-haxe-property-is-an-error`). A physical one (`@:isVar`, or with a default read or write) is
    gencs's plain field, which inline C# reads directly, bypassing the getter (`inline-cs-physical-property`).
  - A .NET call binds past nothing C#'s member lookup would stop at: a derived class's public or protected
    field, property or event of a delegate type hides the base classes' methods of its name, so a call of it
    is refused (`inline-cs-hidden-base-method-is-an-error`), as is one past a member of the type object or a
    type parameter, which may be `dynamic`. A member a call cannot invoke (a `new string Y` property) is left
    out of the lookup, as Roslyn does, so `Y()` binds the base method (`inline-cs-hidden-not-invocable`).
  - `cs.Syntax.plainCode` is parsed, but its names are not resolved in the Haxe scope.
  - In an abstract's method, `this` is the abstract's underlying value (`inline-cs-abstract-this`), and an
    abstract instance method named by its simple name is not lifted (CS0103).

  DCE. A member the lift turns into a placeholder is a real use, so DCE keeps it. A member named only
  through a qualified type name, if DCE removed it, is a lasting error naming `@:keep` (gencs: CS0117).

  Result conversion is gencs's. `untyped __cs__` takes its use's type through C#'s implicit conversions
  only, else a lasting error with C#'s code (CS0266/CS0029). `cs.Syntax.code` is `Dynamic`: to `Int`,
  `Float`, `Bool` and `String` it converts through `Runtime.toInt`/`toDouble`/`toBool`/`toString`, and
  to anything else by C#'s explicit cast from the expression's own CLR type. A `Null<T>` argument is
  boxed, as gencs's `toDynamic()` does.

  Rethrow rules. Each of these emits IL `rethrow` when the innermost enclosing handler is a catch, in the
  catch body or in a try block inside it:
  - the bare `throw` (inline C#, both spellings);
  - `cs.Lib.rethrow(e)`, which the std writes as `throw untyped __rethrow__`;
  - the exceptions filter's own `throw _g`, when no catch matched. This is gencs parity: it writes `throw;`;
  - `throw e` of the innermost catch's own variable, when that catch never assigns it. This is the first-class
    form below, and a recorded divergence: gencs writes `throw e;`, which resets the stack trace.

  A bare `throw` or `cs.Lib.rethrow` anywhere else is a lasting error (C# error CS0156): outside a catch, in
  a local function, or in a finally handler. hxc's own try/finally (`__lock__`, `cs.Lib.lock`) inside a catch
  puts its body in a try block nested in the catch handler, so a rethrow there is valid
  (`inline-cs-rethrow-in-lock`); only its finally handler, which holds no Haxe code, would refuse one. Any
  other `throw e` is a plain `throw`: an assigned `e`, an outer catch's variable thrown from a nested catch,
  and the `haxe.Exception` and `Dynamic` catches, which throw a call's result.

  This covers the server app's 4 patterns unchanged, plus the 5 `__cs__` uses in the `haxe-strings` haxelib
  (`StringBuilder.hx` lines 134/201/278/350, `Strings.hx` line 1366), so no third-party library has to
  be forked. Because the server app agreed to small source changes, these first-class forms are offered too,
  and the server app can move to them over time:
  - **rethrow**: `throw e` inside a `catch`, where `e` is the caught value, emits `rethrow`.
  - **multi-argument indexers**: `x.get_Item(a, b)` and `x.set_Item(a, b, v)`, which compile under both
    compilers.
  - **`#pragma`** in `@:classCode` is ignored, since C# compiler warnings don't exist at the IL
    level. Other `@:classCode`/`@:functionCode` content is an error, and the class is still compiled, so its
    uses do not cascade into "left out" errors. The replacements: hand-written `@:native` externs for what a
    `@:classCode` injected (ruling 8), and `#if !dotnet` around a `@:functionCode` (ruling 9).
- **Nullability metadata**: for types the AI tool schemas see, emit `NullableAttribute` /
  `NullableContextAttribute` as Roslyn does for gencs's C# under the server app's `#nullable enable` patch:
  gencs writes `string` for both `String` and `Null<String>`, so every reference type is non-null. Semantic
  Kernel reads these through `NullabilityInfoContext`. The schemas the server app's build produces today must
  come out identical; `ai.tools` gets non-null `string`, other namespaces unchanged (`-D dotnet-nullable`,
  milestone 4c).
- **Attributes**: `@:strict(...)` and `@:meta(...)` become CustomAttribute rows with properly encoded
  blobs, typed against the referenced assemblies.
- **Resources**: Haxe `-resource` files and a macro's `Context.addResource` resources become manifest
  resources, named so `haxe.Resource` works and C# reads them with `GetManifestResourceStream`. There is no
  `-D dotnet-embed` (4c ruling 8): `TutorialTools.hx` finds `coach.bin` / `tutorials.bin` in
  `GetManifestResourceNames()` by `endsWith`, which `src.Resources.coach.bin` satisfies, so the server app's
  hxml gains two `-resource` lines (an owner change).
- **What `HaxeServer.csproj` does besides compiling** *(my call)*: its package references (PDFsharp,
  PuppeteerSharp, PemUtils, System.Text.Json, …) and project references (Database,
  Database_Single, EPPlus) move to `cs/Server`'s project, which references the prebuilt
  `HaxeServer.dll` by `<Reference HintPath>`. hxc writes no `.deps.json` or nuspec; the consuming
  project produces those, as it does today.
- **Debug info**: a Portable PDB with Document rows (`.hx` paths + SHA-256), sequence points per
  expression statement, hidden sequence points for generated code, local scopes and variable names.
  Embedded source and Source Link are optional. The DLL links to it through CodeView and PdbChecksum
  debug-directory entries. `-debug` does not turn off JIT optimization: the server app build always
  passes it, and under gencs the `dotnet publish` configuration decided optimization instead
  (`HaxeServer.csproj` sets no `<Optimize>`, so only `-c Release` was optimized, and several of
  the server app's Docker scripts publish with `-c Debug`). The assembly gets a `DebuggableAttribute` with
  `DisableOptimizations` only under `-D dotnet-debug-jit`, for stepping with every local kept live.
  *(The define's name is my call.)*
- **Verification**: `dotnet-ilverify` (10.x) runs on every generated test assembly. Differential
  tests compare against Haxe 4.3.7 gencs output (built with `dotnet build`) running the same program,
  with stdout and `haxe.Serializer` output diffed.

## Milestones (suggested order; the builder may reorder)

1. **`--net-lib` / `--net-std` reader.** ECMA-335 metadata reading, converted into extern Haxe types
   like Haxe 4.3.7's net-lib loader does (`@:csNative`, `@:libType`, `@:delegate`, `@:event` metas
   already exist in `src/hxc/data/Metas.hx`). **Exit:** hxc type-checks the server app with
   `--no-output` and reports the same diagnostics as Haxe 4.3.7. Useful even before any codegen.
2. **Writers + minimal emitter.** Metadata tables/heaps, PE writer, IL encoder, a small program with
   classes, statics, strings, arrays, exceptions. A cast between instantiations of a generic class
   is a compile error until milestone 3. **Exit:** runs on `dotnet`, ILVerify clean, deterministic.
3. **Runtime parity.** hxc's runtime copy compiled through the generator; `Dynamic`, reflection,
   enums, closures, anonymous objects, `Null<T>`, `Std`/`Type`/`Reflect`, Serializer, and generic
   instantiations as in *Casts between generic instantiations*: type-argument erasure, companion
   interfaces, `X_cast` and `__hx_cast`, and `Array` casts that share storage (issue 8314).
   **Exit:** the differential suite against Haxe 4.3.7 gencs passes, apart from the recorded
   divergences (the 8314 forward, the parent casts, and the paths left working).
4. **Interop.** `@:nativeGen`, attributes, properties, nullability, delegates/events, overloads,
   generics that cross into referenced assemblies, the inline-C# subset, the indexers gencs gives a
   class with `__get`/`__set` (`Array`'s companion indexer among them), manifest resources (`-resource` and
   `Context.addResource`). It is split into three plans:
   - **4a (done):** what the server app and the desktop app need from referenced assemblies to
     lower: `System.Nullable<T>`, `null` into a .NET value type (`default(T)`, as gencs gives it) and
     `==` against `null` on one; generic .NET method overloads; nested .NET types, and types that no
     supplied assembly defines, read for lowering only from beside the `--net-lib`s or from the .NET
     reference pack; hand-written `@:native` externs and their optional arguments; .NET indexers; .NET
     interface properties and `@:property` vars; delegates. The bullets below give the rules.
     - Its last step measured the server app classes that milestone 3 left out: `CSServer` and the
       `ai.*` chain, 24 classes and about 13.9k lines, held back by IChatHandler (properties of .NET
       interfaces) and `ToolPlugin.ToolFunction` (a nested type of the `--net-lib` `Shared.dll`,
       whose dotted name hxc split into a namespace). A class whose declaration fails gets no plan,
       so their bodies had never been lowered. They now lower with no error: no 3c-type refusal
       (casts, companions, the `Array` forward, generic reflection) was hidden there, and the 146
       delegate conversions they exposed compile.
     - What is left is 4b's and 4c's. The server app has 22 errors (milestone 3c: 222), all inline
       C#: 17 `__cs__`, 2 `@:functionCode`, 1 `@:classCode` and 2 uses of the class that it leaves
       out. Its nativepdf build has 4 (3c: 4), of the same kinds. The desktop app has 10 (3c: 12):
       9 `cs.Syntax.code` and its embedded resources, with or without the Avalonia `--net-lib`s. No
       standard-library method either app calls is stubbed.
     - A hand-written extern method binds the .NET method C# would bind for a call with its declared
       types, under a restricted rule: the exact signature first, else the one applicable overload
       (implicit conversions: identity, upcasts, boxing, numeric widening but to `decimal`, `A` to
       `Nullable<A>`; then an omitted tail of optional or `params` parameters, filled as Roslyn fills
       them; a generic method's type arguments taken from the declared types, as for the server app's
       `JsonSerializer.Serialize(obj:Any)`). Two applicable overloads are a compile error where C# would
       pick the more specific one (`netlib-extern-ambiguous-is-an-error`), and so is a return, field or
       property type that does not convert implicitly, or a variable declared static over an instance
       member or the other way. A Haxe-optional value-type argument (`?b:Int`) stays refused, left out or
       passed, as gencs's C# fails there (CS1503). A converted `--net-lib` member still binds only its
       exact signature. These amendments keep hxc from picking an overload by accident:
       - **Unknown applicability.** A candidate or conversion outside hxc's model of C# may apply: a
         variant generic interface or delegate target, `Span`/`ReadOnlySpan`, `decimal`,
         `nint`/`nuint`, `Nullable<B>` from another type, a type declaring `op_Implicit`, an array to
         a generic interface or another array, a `params` array's expanded form, a generic candidate
         with a type argument the declared types do not give or with any constraint, and a protected
         member that ruling R makes inaccessible: the calling class must derive from its type, and the
         receiver's static type must be the calling class or below it. C# then skips the member, which
         hxc does not model. A call that such a candidate
         may also take is refused ("more than one .NET overload of T.m may accept (…)", or "hxc cannot
         tell whether the .NET method T.m accepts (…)" when it is the only candidate), as
         `String.Concat(a:NativeArray<Int>)` is (`netlib-extern-unknown-candidate-refused`; C# binds
         `Concat<int>(IEnumerable<int>)`).
       - **Link by link.** The chain is walked from the most derived type, and an override is a candidate
         only where its method was first declared. In a link, the one exact match binds, else the one
         applicable method when nothing else may apply; a link passes to the next only when nothing in it
         applies or may apply. So a derived `Foo(object)` beats a base's exact `Foo(string)`, as in C#.
         The walk starts at the receiver's static type: for an instance call, the .NET type of the
         receiver expression's extern class (or of its nearest extern superclass that has one), not the
         extern class declaring the Haxe field; for a static call, the class the call names. So
         `new FDerivedD().F(x)` finds `FDerived.F(IFoo)` although the field is declared on the extern
         `FBase` (`netlib-extern-receiver-type-starts-the-walk`). Through an extern interface receiver
         that extends the declaring extern interface, the call binds as declared, unless a .NET interface
         between the receiver's .NET type (included) and the declaring one (excluded) declares a method,
         property or event of the same name: C#'s interface member lookup may then bind it, which hxc does
         not model, so the call is refused ("the .NET method T.m is also declared on I; hxc does not model
         C#'s interface member lookup", `netlib-extern-interface-receiver-hidden-refused`,
         `netlib-extern-interface-receiver-diamond-refused`). A type-parameter receiver counts as its one
         constraint, as gencs casts it, when that is an extern class or interface with a .NET type or a
         Haxe class below one (`netlib-extern-type-parameter-receiver`); with several constraints or none
         of those, a hand-written extern's call is refused ("hxc cannot tell which .NET overload of T.m the
         type parameter T's constraints select").
       - **Fields and properties** are looked up the same way, from the receiver's static type (its extern
         class's .NET type, or its one constraint's), for a read, a store and an address, so a derived
         class's `new` member hides the base's (`netlib-extern-field-hidden-by-receiver`). The lookup takes
         the public members and the protected ones ruling R allows; a protected one it does not allow is
         refused ("hxc cannot tell whether the protected .NET member T.f is accessible here",
         `netlib-extern-protected-field-refused`), as C# looks further up there, and a private or internal
         one is passed over. A property is as accessible as its most accessible accessor, and an accessor
         that is not accessible is left out.
       - **Argument types.** At a call, the arguments' own types (what gencs's C# sees) must bind the same
         method definition as the declared types, or the call is refused ("the .NET overload of T.m
         depends on the argument types (…); declare it with @:overload"). An `@:overload` extern is
         exempt: gencs casts its arguments to the declared types. An argument's own type counts as
         declared when it is Dynamic or has no signature, or when it is a `haxe.lang.Null<T>` and the
         declared type is not one (gencs unwraps or wraps it, a basic-typed argument to a declared
         `Null<T>` included: `T1(x:Null<Float>)` with an `Int` is ``T1<haxe.lang.Null`1>``), or when it is
         a basic type (`Bool`, the
         integers, `Char`, `Single`, `Float`) and the declared type is another one, as gencs casts it
         (`T1(x:Float)` with an `Int` is `T1<double>`, and `N(int)`/`N(double)` binds `N(double)`;
         `netlib-extern-basic-argument-cast`). A generic method's type arguments come from
         the arguments' own types, as C# infers them (`T1(x:Any)` with a `MyPlain` is `T1<MyPlain>`, a
         TypeDef or TypeSpec of the program's own module, and with an `x:U` of a Haxe class or method type
         parameter it is `T1<!0>`, no box. An unconstrained type parameter's argument is its own type, and the
         method C# picks for it is the one called, `P<T>(T)` over `P(object)`; a call C# finds ambiguous or no
         method for (CS0121, CS1503) is refused, never bound by the declared types. A constrained type
         parameter's argument is the declared type, as gencs casts it, also in a call that mixes both kinds); where they differ from the
         declared ones, the declared return type must still convert from the method's return with them, or the call is
         refused with the return-mismatch error.
       - **Argument values.** C# also converts by an argument's value, and gencs writes integer literals
         and `null` as they are; it casts an `@:overload` extern's arguments to the declared types, which
         keeps an integer constant one, and writes a `null` into a value type as `default(T)`. In both
         bindings, an integer constant (an `Int` literal or a fold of them) may also take a narrower
         integral parameter it fits (`sbyte`, `byte`, `short`, `ushort`, `uint`, `ulong`), and a 0 an enum,
         both unknown, while identity with `int` stays exact and a widening applies. So `B(5)` with
         `B(byte)` and `B(object)`, `S(5)` with `S(short)` and `S(double)`, `E(0)` with `E(Hue)` and
         `E(object)`, and the same for a constructor are refused, where C# picks the first of each by
         betterness, and the message adds "C# converts an integer constant or null argument by its value;
         declare the parameter's exact type, or use @:overload"
         (`netlib-extern-int-constant-to-byte-refused`, `…-to-short-refused`,
         `netlib-extern-zero-to-enum-refused`, `netlib-extern-int-constant-constructor-refused`). `I(5)`
         with `I(int)`, `B(300)`, and a `null` into the one reference candidate still bind
         (`netlib-extern-constant-and-null-arguments`). An indexer's index is such an argument too
         (`netlib-indexer-zero-to-enum-refused`).
       - **A `null` argument (ruling Z).** A `null` literal, the typer's padding of a left-out optional
         argument included, applies to every reference type and to a `params` array in its normal form, and
         is never an exact match, even against `object`; it gives a generic method no type argument, so one
         whose type parameter no typed argument gives does not apply, as C#'s inference fails. A `null` into
         a declared `Nullable<T>` (or any value type) is typed as declared, as gencs's `default(T)` is. Among
         several applicable overloads, the one better than every other one binds, by C#'s betterness: at a
         null position a parameter type is better when it converts to the other one's and that one does not
         convert back (a reference type converts to no `Nullable<T>` unless a user-defined conversion may
         apply); positions of the same type are neutral, and the leftover parameters are not compared. So
         `S2(null)` with `S2(string)` and `S2(object)` binds `S2(string)`, `N(null)` with `N(Thing)` and
         `N(object)` binds `N(Thing)`, `P(null)` with `P(params object[])` and `P(object)` binds the params
         one with a null array, a padded `O(1)` binds `O(int, Thing)`, and inline C# alike
         (`netlib-extern-null-betterness`, `…-conversions`, `netlib-extern-null-to-declared-nullable`,
         `inline-cs-null-betterness`). Where every comparison is known and no overload is better than every
         other one, C# reports CS0121 and the call is a lasting error ("…, and for a null argument C# finds
         none of them better than the others (gencs's C# fails, CS0121); pass a variable of the parameter's
         type, or use @:overload", `netlib-extern-null-ambiguous-is-an-error`). Where one is not, a typed
         argument whose parameters differ (hxc does not model C#'s betterness for one) or a conversion hxc
         does not model (`Nullable<A>` to `Nullable<B>`, array covariance), it is refused with "…, and hxc
         cannot tell which one C# picks for a null argument; …"
         (`netlib-extern-null-betterness-unmodelled-refused`). A declared `Nullable<Int>` that no overload
         takes is refused as any declared type is, where gencs's C# fails with CS1503
         (`netlib-extern-null-to-declared-nullable-mismatch-is-an-error`).
       - **Haxe-compiled types.** A Haxe class or interface keeps its own type in either binding (a
         declared parameter type can be one too): no identity match fires for it but against that very
         type. It converts for certain to `object`, to the classes on its Haxe superclass chain and the
         interfaces implemented along it, directly or through Haxe interfaces, the extern ones with their
         .NET supertypes, and, for a `@:struct` class, to `System.ValueType`; a Haxe interface to its base
         interfaces likewise. It converts to nothing else, except that a variant generic interface or
         delegate not on that list may apply (unknown), as C#'s variance is not modelled. As ruling 1
         binds only the one applicable method, a single overload taking the interface binds
         (`netlib-extern-haxe-class-implementing-net-interface`), and `Baz(object)` next to
         `Baz(IDisposable)` is refused (`netlib-extern-haxe-class-implementing-net-interface-refused`),
         as are `Bar(Exception)` next to `Bar(ArgumentException)` for a subclass of `ArgumentException`
         and `Vt(ValueType)` next to `Vt(object)` for a `@:struct` class, where C# picks the more specific.
       - **Instantiation.** Both bindings
         take the call's type arguments for the class's and the method's type parameters, so
         `List<int>.Add(T)` takes an int; where that makes two candidates take exactly the arguments
         (`Gen<int>`'s `Foo(T)` and `Foo(int)`), the call is refused, where C# prefers the parameter that
         is not a type parameter.
     - An `@:overload` override that changes only the return type is refused. gencs compiles it as a C#
       covariant-return override, which needs `newslot`, a MethodImpl row and
       `PreserveBaseOverridesAttribute`.
     - `a[i]` on an extern class with a .NET indexer is a call of its `get_Item` or `set_Item`
       (`netlib-indexers`). The indexer is the one C# picks for an `int` argument. Walking the class's
       .NET chain from the receiver's class (a Haxe class's nearest extern superclass), it is in the
       first class that declares an accessible one-parameter property named by its
       `DefaultMemberAttribute`. Explicit interface implementations (named by the interface) and
       overrides (which C# looks for where the base declared them) are left out
       (`netlib-indexer-override`). There the indexer is the one whose parameter is `int`, else the one
       `int` converts to implicitly. A class's own indexer hides the base's, as in C#
       (`netlib-indexer-inherited`).
       - A protected indexer is accessible only under ruling R: the calling class derives from the
         declaring type, and the receiver's static type is the calling class or below it
         (`netlib-indexer-protected`). Otherwise it may apply, which refuses the access, as C# picks
         another indexer there (`netlib-indexer-protected-is-an-error`,
         `netlib-indexer-protected-base-receiver-is-an-error`).
       - Two applicable indexers, or one hxc cannot tell applies, are refused, where C# would pick the
         better one (`netlib-indexer-ambiguous-is-an-error`). A store to a get-only indexer is refused
         (`netlib-indexer-readonly-is-an-error`).
       - Compound assignment, `++` and `--` read once and store once, on the receiver and index
         evaluated once (`netlib-indexer-compound`). Through a .NET struct's indexer they are refused,
         with a Dynamic operand too, where gencs evaluates the receiver once into a copy
         (`netlib-indexer-struct-compound-is-an-error`).
       - The element type the typer gives is Dynamic for a generic class, else that of the class's first
         one-parameter property, which need not be the bound indexer. It must convert to and from the
         bound indexer's type as the access needs, or the access is refused, where gencs's C# fails
         (`netlib-indexer-element-mismatch-is-an-error`).
       - The element of a converted extern is typed Dynamic: a read passes a struct or `Nullable`
         element as an object, which Runtime converts (`netlib-indexer-nullable-elements`).
       - The value of an assignment through an indexer, a .NET property or a .NET field is the value
         stored, kept across the call, not what a setter returns (`netlib-property-store-value`,
         `netlib-field-store-value`); `op=` and `++`/`--` on a .NET field work as values too.
     - A Haxe class implements the properties of a .NET interface converted from a `--net-lib` as gencs
       does (ruling 7; `iface-property-bcl`, `netlib-iface-properties`). gencs's InterfaceProps picks the
       vars: one with a get or set accessor, named as such a var of an interface its class lists itself.
       Each becomes a CLR property with a Property row: the Haxe `get_X` and `set_X` are private,
       non-virtual `_get_X` and `_set_X`, and public `get_X` and `set_X` accessors (`void set_X(T)`) call
       them. The accessors are `virtual newslot` when the class declares both and neither they, the var nor
       the class is final, else `virtual final newslot` where they implement an interface method. An
       override of an accessor makes an override property with only the accessors the class declares
       (`netlib-iface-property-override`, `netlib-iface-property-setter-override`). Every Haxe use calls
       the public accessor, reflection included, and the value of a set call is its argument
       (`netlib-iface-property-set-only`). C# code reads the values the Haxe getters return
       (`netlib-iface-property-from-csharp`). A property of the .NET base class implements the interface
       property of a Haxe subclass that lists the interface when each accessor the interface declares is a
       public virtual method of the base, with exactly the interface's signature
       (`netlib-iface-property-base-virtual`).
       - Errors, as gencs's C# does not compile: an override of an accessor of a property that is not
         virtual, such as the getter of a get-only one, at the override (CS0506,
         `netlib-iface-property-getonly-override`); a var whose class does not list the interface
         itself, which a Haxe interface extending it or a superclass would give (CS0535,
         `netlib-iface-property-not-listed-is-an-error`); a physical var (CS0535,
         `netlib-iface-property-physical-is-an-error`); a var or an accessor of another type than the
         interface property's (CS0738, `iface-property-type-is-an-error`); and a property of a
         hand-written extern interface (CS0535).
       - Not supported yet: a non-virtual property of the .NET base class implementing the interface
         property, for which C# adds a forwarding stub (ruling S,
         `netlib-iface-property-base-nonvirtual-is-unsupported`; the stub is milestone 4c's), properties
         of generic classes, events, and overloaded, generic, dynamic or abstract accessors.
       - An interface method (of a .NET or a Haxe interface) that a method of the .NET base class
         implements is the same: the base method must be public and virtual with exactly the
         interface method's signature (`netlib-iface-method-base-virtual`), and a non-virtual one
         is refused ("an interface method (I.m) implemented by a non-virtual method of the .NET base
         class B is not supported yet", `netlib-iface-method-base-nonvirtual-is-unsupported`), where
         hxc used to write a type the CLR could not load.
     - A physical `@:property` var is a CLR property, as gencs writes it a C# auto-property (ruling 8;
       `property-meta-vars`, `property-json`): a private `<X>k__BackingField`, public non-virtual
       `HideBySig | SpecialName` accessors `get_X` and `void set_X(T)` that read and write it, static for a
       static var, and a Property row. Every Haxe access calls the accessors: the initializers, which run
       in the constructor or the static constructor, compound assignment and `++`, Dynamic access,
       reflection and a hxgen class's reflection members (`property-vars-access`, which also covers a
       generic class and a struct). A member of a struct-typed one is reached through a copy of the
       getter's value, as in C#. System.Text.Json and .NET reflection see the properties, and no field.
       The backing field and both accessors carry Roslyn's `CompilerGeneratedAttribute`
       (`property-var-compiler-generated`).
       - Error, as gencs's C# does not compile: a `get_X` or `set_X` the class declares beside the var
         (CS0082, `property-var-accessor-clash-is-an-error`).
       - A non-physical `@:property` var with a get or set accessor is a property as gencs's gen_prop
         makes one, the same as a .NET interface property's implementation above (ruling T,
         `property-var-accessors`): private `_get_X`/`_set_X` bodies, public accessors (`virtual newslot`
         with both and nothing final), an override property for a subclass's override of an accessor, and
         the argument as a set call's value. Not supported yet: a static one, which gencs makes a static
         property (`property-var-static-accessors-is-unsupported`), and one in a generic class, where
         gencs's C# for a hxgen class fails (CS0686).
     - A Haxe function converted to a .NET delegate, the `cast __delegate__(f)` that a delegate abstract's
       `new` and `@:from` leave, takes gencs's three shapes (ruling 9; `netlib-delegates`,
       `netlib-delegates-methods-and-combine`, `thread-create`):
       - A local function's closure class gets a public non-virtual `Delegate` method with the function's
         own argument and return types, holding its body; its invoke method calls it. The delegate is made
         from that method on the class's instance, the cached `__hx_current` when nothing is captured.
       - A static method, or an instance method's closure, is a method group: `ldnull` or the receiver,
         `ldftn` (`dup; ldvirtftn` for a virtual method), then the delegate's `.ctor(object, native int)`.
         A handler made again from the same method is equal to the first, so it removes it.
       - Any other function value (a local, a bound call, a closure the inliner put in a local) gets a
         conversion wrapper: a closure class capturing the value, whose `Delegate` calls it.
       - The delegate abstract's `+` and `-` are `Delegate.Combine` and `Delegate.Remove`, cast back.
       - Error, as gencs's C# does not compile (CS0030) or its cast throws at run time: a method whose
         parameter and return types do not convert to those of the delegate's `Invoke` as C#'s method
         group conversion allows (the same type, or a reference conversion from the `Invoke`'s parameter
         and to its return). That includes a delegate going on as another instantiation of its type, as
         Haxe unifies `Func_2<Int, Bool>` with `Func_2<Dynamic, Bool>`. gencs casts the delegate to the
         other instantiation. Its C# does not compile there (CS0030, `delegate-type-mismatch`), except
         where the two type arguments are reference types of a variant delegate's parameter, such as
         `Func_2<String, Bool>` to `Func_2<Dynamic, Bool>`: that compiles, and the cast throws
         `InvalidCastException` at run time.
       - A method group over a virtual method dispatches as C#'s does: through a subclass, base-class or
         Haxe interface receiver it runs the override, two delegates over the same object and method are
         equal, and `Method.DeclaringType` is the class declaring the method run
         (`delegate-method-group-virtual-dispatch`). `-` and `-=` remove a delegate, and removing the last
         gives `null` (`delegate-remove`).
       - Not supported yet as a method group: a .NET method, an overloaded method, a struct's method, and a
         method reached through a `Dynamic` or companion-interface receiver.
   - **4b (done):** the inline-C# subset (`__cs__`, `cs.Syntax.code`, `@:functionCode`, `@:classCode`),
     gencs's indexers from `__get`/`__set` (`Array`'s and its companion's included, not hxcs's
     `@:classCode`), the remaining standard-library stub (`Socket.select`, which calls a
     method on an `IntPtr` property's value; `new IntPtr(n)` is refused too), and Roslyn's
     `CompilerGeneratedAttribute` on a `@:property` var's backing field and accessors.
     - Its last step measured the apps. The server app needs two source changes, which keep gencs's output
       the same: nativepdf `Zlib`'s `@:classCode` becomes hand-written `@:native` externs for `ZLibStream`
       and `CompressionLevel` (ruling 8), and its library's two constructor `@:functionCode`s, dead code in
       both apps, go in `#if !dotnet` (ruling 9). With them, the server app and its nativepdf build have
       no error and each writes its DLL (4a: 22 and 4). Without them, the server app has 4 errors (the
       `@:classCode`, the 2 `@:functionCode`s, and the `zlibNative` call the `@:classCode` declared, an
       unknown name) and nativepdf 2. The desktop app's only error is its embedded resources (4c), with
       or without the Avalonia `--net-lib`s (4a: 10). No standard-library method either app calls is
       stubbed; across the whole std, `cs.Pointer.add` is the one stub left (`haxe.ds.EnumValueMap`, the one
       class 4b left out, is written since 4c: a final or inline method of a Haxe base class that an interface of
       a subclass maps to is `virtual final newslot` in its own class, as Roslyn writes it).
     - ILVerify of the server DLL against the deployed assemblies gives only the line gencs's DLL gives
       (`haxe.lang.BoxedPointer`'s unmanaged pointer). The server app's own no-browser export check, run on
       gencs's DLL and on hxc's, prints the same results. The CLR shape of the 24 classes 4a measured and of
       the AI tool models had the same members as gencs's, and differed only in their order (static members);
       4c writes gencs's order, so that difference is gone (`member-order-every-member-kind`).
     - Known limit: a field-level `addMetadata`/`addTypePatch` aimed at a class the core types load before
       the init macros run (`StringTools` on cs, `haxe.EnumTools`) is still missed, where Haxe 4.3.7
       applies it. Only class-level metadata (an added `@:build`) is applied late, and a late patch aimed at
       an abstract reaches its impl class only, not the abstract.
   - **4c:** `@:nativeGen` details, attributes (`@:strict`, `@:meta`), nullability metadata for the AI
     tool schemas, events defined in Haxe (`@:event` vars), manifest resources (`-resource`,
     `Context.addResource`), milestone 4's exit below, and the carried items.
     Attributes are written: each `@:meta` entry (StrictMeta rewrites `@:strict` into one, and its
     `@:cs.assemblyStrict` into `@:cs.assemblyMeta`) is a CustomAttribute row on the member gencs's C# puts
     it on, in meta order, with C#'s type lookup, constructor choice and Roslyn's blob, Type and enum names
     assembly-qualified as Roslyn writes them (4c rulings 3 and 4). `@:meta` with several parameters or with
     C# text, an attribute on a var that is not physical and an argument's `@:strict` are errors, where
     gencs drops or misplaces them, and C#'s attribute errors (CS0579, CS0592, CS0246, CS0616, CS1503,
     CS0182, CS0121, CS1614, CS0617, CS0023, CS1021) are `dotnet:` errors that name them; a literal's Haxe
     suffix types it (`i64` a long, `u32` a uint), and the attribute classes are read from the reference pack,
     which Roslyn compiles gencs's C# against. The attributes the backend writes itself come from
     System.Runtime. The pseudo-attributes are flags and tables, never rows (ruling 5): `Serializable` and
     `NonSerialized` the type's and field's flags, `StructLayout` the layout and CharSet flags with a
     ClassLayout row for its `Pack` and `Size`, and `FieldOffset` a FieldLayout row, with Roslyn's errors
     (CS0636, CS0625, CS0637, CS0842, CS0591, CS0599); Roslyn's others (`MethodImpl`, `DllImport`,
     `MarshalAs`, ...) are errors. This fixes std's `haxe.io.FPHelper`, and so `Bytes.getDouble` and its kin,
     which read and wrote zeros. Every assembly gets the SDK's `TargetFramework(".NETCoreApp,Version=v<net>.0",
     FrameworkDisplayName = ".NET <net>.0")`, and `@:cs.assemblyMeta` entries are assembly rows, refused as
     gencs refuses them on a class that is not its module's first or that has no package; a `@:noCompletion`
     field, property, method or constructor gets `EditorBrowsable(EditorBrowsableState.Never)` (ruling 6).
     A `@:nativeGen` class's methods and constructors, and an abstract's implementation class's static
     methods, get gencs's overloads for their trailing optional arguments, each with the field's attributes
     (`optional-overloads-of-abstract-implementation-class`: the server app's `Guid_Impl_._new()`). A
     `@:nativeGen` class's constrained type parameters still get no GenericParamConstraint rows, so a call that
     passes one to an overloaded .NET method, which gencs's C# binds by the `where` clause, is refused
     (ruling 7). `-D dotnet-nullable=<package>[,<package>…]` writes
     Roslyn's nullable metadata (ruling 2) for every type of a module whose package is exactly one of those
     named, its local functions' classes included, as the server app's build enables gencs's C# with
     `#nullable enable` before each `namespace ai.tools {`; a sub-package's modules are not covered, which
     gives the patch's 34-of-108 model split. The rows are Roslyn's, compressed by its context rules, so a
     dump compares row for row (`attrs-nullable-rows`): each type reference's byte array in pre-order (1 for
     every reference type, since gencs writes no `string?`, 0 for a generic struct such as
     `haxe.lang.Null<int>`; a reference to a type parameter is 1, and only its GenericParam row is 2), `NullableContext` as the most common byte (ties to 0,
     then 1, then 2) where it differs from the enclosing one, `Nullable(0)` for the base type, Param rows of
     sequence 0 for a return value's attribute, the rows before their parent's others, and the attribute
     types from System.Runtime. A value that names no package, and a constrained type parameter of a
     `@:nativeGen` class (gencs writes its `where` clause, hxc no constraints), are errors; the class of a local
     function in a constrained generic method is not one, since gencs writes it no `where` clause
     (`attrs-nullable-closure-of-constrained-method`: a data helper class's `byId` in the server app). Events defined in
     Haxe: Haxe's `check_cs_events` runs for the C# target before DCE (`@:event fields must be private`,
     `Missing event method: add_X`, and the unification error at an add_ or remove_ that is not `T -> Void`),
     and gencs hides every `@:event` var from reflection (`@:skipReflection`), so hxc does too. An `@:event`
     var of (default, default) access is a C# event (EventToIl), as gencs's `gen_event` writes it: an Event row
     and an EventMap row (statics first, then instances, each last declared first) and public `add_X(value)`
     and `remove_X(value)` accessors (SpecialName, Static for a static event, Family for a `@:protected` var;
     MethodSemantics AddOn and RemoveOn); the var has no field and, as in gencs, no attribute (its `@:meta` is
     dropped). Every Haxe call, closure and reflection invoke of add_X and remove_X goes to the accessor, as
     gencs writes `o.X += h`. The event is custom when its `add_X` and `remove_X` are not both empty: the
     accessors call the Haxe methods, which become the private non-virtual `_add_X` and `_remove_X`, and the
     var has no value to read or assign (CS0079). It is field-like when both are empty (gencs's
     `public event T X;`): there are no methods, the accessors are Roslyn's (CompilerGenerated, a
     `Delegate.Combine`/`Delegate.Remove` loop over `Interlocked.CompareExchange<T>` on a private
     CompilerGenerated backing field named as the var), and the var is that field inside its own class and has
     no value anywhere else (CS0070). A Haxe interface's `@:event private var` is a C# interface event: its
     `add_X` and `remove_X` are the abstract accessors (CompilerGenerated), and the accessors of an event of a class
     that implements one are virtual and sealed; the class must have an `@:event` var of that name, for a .NET
     interface's event too (else CS0535). Where gencs's C# fails, hxc refuses or does better, each recorded in
     *Interop divergences from gencs*, and hxc's DCE keeps an event's var and both methods together. An
     `@:event` var with any other access is a plain variable, as haxeui's builder macro leaves them. With
     `-D dotnet-nullable`, an event has the Nullable attribute of its type (Roslyn's), and does not count in its
     type's context.
     Resources are manifest resources (ruling 8): each is named `src.Resources.` plus its name as
     `haxe.Resource` escapes it at run time (`Path.escape(name, true)`, per UTF-16 code unit: every unit but
     `A-Z a-z 0-9 _ . / \` becomes `-x<code>`), which is gencs's name for every ASCII name without `\`. The
     ManifestResource rows (public, in this file) go in `resourceFoldOrder()`, the order hxcs passes them to csc,
     and the blob follows the metadata as Roslyn's does: each entry a 4-byte length and the bytes, padded to 8
     bytes, the last one included; the CLI header's Resources directory points at it, and a DLL without
     resources is unchanged. `haxe.Resource.content` lists the names in the reverse of that order, an empty
     array when there are none, as gencs's `static Resource()` does. Two names with one manifest name are an
     error. The desktop app's build depends on the macro-API fix (ruling 9): 158 of its 217 resources come from
     haxeui-core's macros, which hxc's `Context.addResource` used to drop.
     - Its last step measured the apps, with the owner's changes below standing in as an overlay. The server app, its
       nativepdf build and the build with the stubbed report have no error and each writes its DLL (4b: the same),
       and the server's DLL has the two manifest resources, `src.Resources.coach.bin` and `src.Resources.tutorials.bin`,
       of gencs's sizes (5,044,147 and 2,644,821 bytes). The desktop app has no error (4b: 1), with its UI natives
       DLL rebuilt from the current sources (the prebuilt one lags them, and gives 9 correct "unknown field"
       refusals), and writes all 217 manifest resources, named as gencs's build names them. It found two things, both fixed: the nullable metadata
       refused the classes of local functions in a constrained generic method (a data helper class's `byId`), for which
       gencs writes no `where` clause; and an abstract's implementation class lacked gencs's optional-argument
       overloads (`Guid_Impl_._new()`). The baseline is gencs's C# of the same source tree with the build script's four
       text patches applied, which is what the build script produces; gencs's C# alone has no nullable metadata.
       Against it:
       - `SharedServer`, `WebAPI`, `Server` and the no-browser runner build against hxc's DLL with no error and the
         warning kinds and counts they have against gencs's. The 14 `?x:Bool` arguments that failed to compile
         against the research build now pass, because `haxe.lang.Null<T>` converts implicitly from `T`. All 349
         type and member references the consumers compiled against gencs's DLL make into it resolve in hxc's, and
         the 349 of those compiled against hxc's resolve in gencs's. Every non-generic method of the DLL (24,873 in
         5,948 types) and of the consumers JITs in the deployed server's folder, in each of the three pairings.
       - ILVerify against the deployed assemblies prints nothing, as for gencs's patched DLL. Run on the older
         deployed DLL, which still has `haxe.lang.BoxedPointer`, it prints that class's line, so the check can fail.
       - The AI tool schemas, from Semantic Kernel over each DLL, are identical for all 133 tools, descriptions,
         `required` lists and nullability included.
       - The server app's no-browser export check prints the same results on both DLLs (the PDF and DOCX sizes
         differ by a few bytes, as two gencs runs' do: timestamps). The gencs DLL it compares with is the older
         one in the runner's folder, not the fresh baseline build.
       - The CLR shape of the 24 classes and the 110 tool models has the same members. What it prints beyond that
         is `DebuggerBrowsable(Never)` on 304 `@:property` backing fields and the Field-table order of two classes
         (*Interop divergences*).
       - The attribute rows differ only by what the SDK and Roslyn add to gencs's build (the assembly's Company,
         Configuration, FileVersion, InformationalVersion, Product and Title, `CompilationRelaxations`,
         `RuntimeCompatibility` and `Debuggable`, the module's `RefSafetyRules` and `UnverifiableCode`,
         the DeclSecurity row, `DebuggerBrowsable`, `<PrivateImplementationDetails>`), and by the nullable rows of
         the closure classes hxc has more of (3,759 against 2,251).
     - The owner's changes, in one place. The measurement stands in for them with an overlay, and the server app's
       files stay as they are until the owner makes them:
       - the two source changes from 4b: nativepdf `Zlib`'s `@:classCode` becomes hand-written externs (4b ruling 8),
         and the app's library's two constructor `@:functionCode`s go in `#if !dotnet` (4b ruling 9);
       - the server's hxml gains `-resource <path>/coach.bin@coach.bin` and `-resource <path>/tutorials.bin@tutorials.bin`
         (the files `HaxeServer.csproj` embeds today), and `-D dotnet-nullable=ai.tools`;
       - the C# projects that name Haxe types (`SharedServer`, `WebAPI`, `Server`, and the no-browser runner) import one
         shared `.props` holding `<Reference Include="HaxeServer"><HintPath>…</HintPath></Reference>`, in place of
         `SharedServer`'s `ProjectReference` to `HaxeServer.csproj`; `SharedServer` takes that project's package and
         project references (`Database`, `Database_Single`, `EPPlus`, `PemUtils`, `System.Net.Http`,
         `System.Security.Cryptography.Algorithms`, `System.Text.Json`, `System.Text.RegularExpressions`). A
         `<Reference HintPath>` does not flow to the projects that reference `SharedServer`;
       - `Builder.hx` then drops its four text patches: deleting `BoxedPointer.cs` and `Pointer.cs` (hxc writes
         neither class), the `thx.Options` chunk (dead code under DCE) and `#nullable enable` before
         `namespace ai.tools {` (`-D dotnet-nullable=ai.tools`), and runs hxc instead of `dotnet build` of
         `HaxeServer.csproj`.
     - **Not supported**, and clean compile errors past milestone 4, because nothing in the two apps uses them:
       - covariant-return `@:overload` overrides;
       - the forwarding stub C# adds where a .NET base class's non-virtual method or property
         implements an interface method or property for a Haxe subclass (ruling S), and where a Haxe
         superclass's event implements a Haxe or .NET interface's event for a subclass that lists the
         interface (`event-interface-event-of-superclass-is-unsupported`);
       - static `@:property` vars with get or set accessors, which gencs makes static properties;
       - .NET extern, overloaded and struct methods as delegate method groups, and a method group
         reached through a `Dynamic` or companion-interface receiver;
       - two refinements of the overload rule for inline C# (4b's `converts`): the lifted conversion
         `Nullable<A>` to `Nullable<B>`, and array covariance;
       - `{0}[i]` on a program class in inline C#;
       - `cs.Pointer.add`, the one standard-library stub (the `+` operator on pointers);
       - a .NET field, method or property accessor whose signature has a required custom modifier (`modreq`), used
         from Haxe or from inline C#. hxc writes no modreq into the MemberRef, and the CLR matches a member's
         signature with its modifiers, so the call or access would throw `MissingFieldException` or
         `MissingMethodException` when run, which `IlMetaTools.ilsigNorm` used to hide by dropping the modifier.
         `ExternMembers` now refuses at compile time: volatile fields (`IsVolatile`), the `in` parameters of virtual
         methods (`InAttribute`) and any other modreq (a `ref readonly` return, say) with a generic message that names
         it. gencs's C# uses all of these, so this is a gap (keeping the modreq in the MemberRef, and writing
         `volatile.` before the access of a volatile field, is the later fix); an init-only setter (`IsExternalInit`)
         is refused, as gencs's C# fails too, except for the assignment in a subclass's constructor, which C# allows
         and hxc refuses as well (*Interop divergences*). Still open with the later fix: a .NET indexer accessor
         with a modreq (`this[int] { get; init; }`) is not refused and throws `MissingMethodException` when run; a
         virtual method with an `in` parameter taken as a value (`var f = v.M;`) goes through the reflective
         closure and throws `ArgumentException` at its first call; and the refusal also covers a Haxe class that
         overrides or implements such a method, where no MemberRef is written, which may be more than needed.
         Neither app reaches any of these (their builds have no error). A member of the same shape without a
         modreq works: a plain field, a non-virtual method's `in` parameter, an init-only property's getter
         (`netlib-modreq-members-are-refused`, `inline-cs-modreq-fields-are-refused`,
         `netlib-modreq-free-siblings-work`);
       - things that were not run or not verified, and no refusal covers: the jvm path of `-resource` and
         `Context.addResource` never ran; the order the cppia generator (`CppiaGen`) writes resources in
         (`com.resources.keys()`) is unverified; and on Windows hxc reads its command line in the ANSI code page,
         so a non-ASCII `-resource` name, `-D` value or path is changed for every target (U+014F arrives as `o`),
         where Haxe 4.3.7's OCaml runtime reads UTF-16. The last is a front-end bug, not a .NET one.
   **Exit:** The server app builds to `HaxeServer.dll`, the projects that name Haxe types (`SharedServer`,
   `WebAPI`, `Server`, and the no-browser runner) reference the DLL through one shared `.props` and build,
   the AI tool schemas match those the server's build script produces today (gencs's C# with its text patches
   applied), ILVerify against the deployed assemblies is clean.
5. **Portable PDB.** **Exit:** breakpoints and stepping in `.hx` files in Visual Studio and VS Code
   (built with `-D dotnet-debug-jit`), and `.hx` line numbers in exception stack traces from an
   optimized build.
6. **The server app acceptance.** The two-way test database migration described in Success.

### Interop divergences from gencs (milestone 4)

Where gencs's output fails at run time or its C# does not compile, hxc either refuses cleanly or does
better. Each case that does better is a test, and each is listed here. Where gencs's build runs, the
test has a `[gencs]` section that shows what it does; where gencs's C# does not compile, there is no run
to compare, so the test is not `@gencs` and the entry quotes the C# compiler's error.

- `HasValue` and `Value` on a `Nullable<Int>` read out of a `Map<String, Nullable<Int>>` work in hxc
  (`netlib-nullable-better`). gencs throws at that first read: `Method "get_HasValue" not found on type
  System.Int32`. The same case also reads through a `Null<Nullable<Int>>` in hxc; gencs never gets
  that far, so the case does not show what it does there.
- A hand-written extern whose .NET supertype lives in an assembly that sits beside a `--net-lib` but
  is not passed compiles and runs in hxc (`netlib-dependency-beside`: `LibA.Panel` extends
  `LibB.BaseCtl`, and only `LibA.dll` is passed). hxc reads `LibB.dll` from beside `LibA.dll` for
  lowering only and references it by that file's identity. gencs's C# does not build, because hxcs
  references only the `--net-lib` files: `CS0012: The type 'BaseCtl' is defined in an assembly that
  is not referenced`. haxeui-cs relies on this when only `HaxeUICs.dll` is passed. With no gencs
  run to compare, the case is not `@gencs`.
- `x == null` on a generic .NET struct or a generic Haxe `@:struct` class is `Equals(object)` on the boxed value and
  the boxed `default(T)`. gencs's C# binds `x.Equals(default(T))` to the struct's own `Equals(T)` when it
  declares one. The two differ only when that `Equals(T)` and `Equals(object)` disagree, which is not
  normally observable. Non-generic structs, .NET or Haxe, bind as C# does (`struct-own-equals-null`).
- A `Dynamic` value stored into a typed .NET indexer converts in hxc (`netlib-indexer-dynamic-write`:
  `li[0] = dyn` on a `List<int>` stores the value through `Runtime.toInt`). gencs's C# writes
  `li[0] = dyn;` and does not compile: `CS0266: Cannot implicitly convert type 'object' to 'int'`.
- Compound assignment, `++` and `--` on a `Dynamic` .NET indexer element (`li[0] += 2` on a
  `List<int>`) call `get_Item` and `set_Item` directly in hxc (`netlib-indexer-compound`), where
  gencs goes through `Runtime.callField(li, "__get")` and `"__set"`. The values are the same; only a
  stack trace through the runtime's reflection would differ.
- A generic .NET method's type argument inferred from a closure, an array literal or an anonymous
  object passed to a hand-written extern is hxc's representation class (`haxe.lang.Function`,
  `Array`, `object`), where gencs's C# infers the closure's own class, ``Array`1`` or
  `haxe.lang.DynamicObject`. Only reflection on the type argument (`typeof(T)`) can tell.
- gencs renames a method type parameter that shadows a class one (`T` is `T1`; the counter is per class, over
  the instance fields, then the statics, and an `@:overload`'s overloads keep their names), and hxc writes the
  same GenericParam names (`method-type-param-renamed`). Two shapes do not compile in gencs's C#, both
  `CS0246`: an override of a renamed generic method keeps the base's renamed name in its signature (`K<T>
  extends G<T>`, `override i<T>(x:T)` is `T1 i<T2>(T1 x)`), and `H<T, T1>.s<T>` fails too. hxc renames by the
  same rule and uses the new name in the whole signature, so both compile and run
  (`method-type-param-renamed-override`; with no gencs run to compare, the case is not `@gencs`).
- A delegate made from a static method is a new delegate each time (ruling 9). Roslyn caches it in a
  `<>O` class, so only reference equality between two such delegates can tell.
- `throw e` of the innermost catch's own, unassigned variable is IL `rethrow` in hxc and keeps the stack
  trace (`rethrow-throw-caught-value`); gencs's `throw e;` resets it. A closure that only reads `e` leaves
  that unchanged (`rethrow-captured-catch-variable`); one that writes `e` makes it a plain `throw`, as in
  gencs.
- A name in inline C# means the Haxe local of that name in scope (`inline-cs-names-haxe-scope`). gencs's C#
  reads what its renamed output has under that name, a silent wrong value in each of the case's lines (its
  `[gencs]` section): a shadowing local that gencs renamed (`sh1`), so the text reads the outer one; a local a
  closure captures and writes, which gencs boxes in an array, so the text prints `System.Int32[]`; and an
  inline function's argument, which the inliner replaced by its value, so the text reads the caller's local
  of that name.
- hxc resolves names gencs's C# cannot, in the Haxe scope where the typer met the inline C#
  (`inline-cs-names-gencs-cannot-resolve`): a local declared in a loop the typer unrolls, the loop variable of
  an unrolled loop, and an outer local only a closure's C# text names. gencs's C# does not compile:
  `CS0103: The name 'col' does not exist in the current context` (and the same for `i` and `outer`). Under `-D analyzer-optimize`, gencs's analyzer also removes a local only `cs.Syntax.code` text
  reads, and a closure's class has no member of the enclosing class
  (`inline-cs-names-gencs-cannot-resolve-optimized`): CS0103 for `b`, `i` and `fld`.
- `this` in the inline C# of an abstract's method is the abstract's underlying value in hxc
  (`inline-cs-abstract-this`). gencs writes the method as a static one, so its C# does not compile:
  `CS0026: Keyword 'this' is not valid in a static property, static method, or static field initializer`.
- A store through a subclass that overrides only `__get` calls the nearest superclass's `set_Item`
  (`haxe-class-indexer-hidden-setter`). gencs gives the subclass its own get-only indexer, which hides the
  base class's, so its C# does not compile: `CS0200: Property or indexer 'Sub.this[int]' cannot be assigned
  to -- it is read only`. The subclass's metadata stays gencs's.
- The mirror: a read through a subclass that overrides only `__set` calls the nearest superclass's
  `get_Item` (`haxe-class-indexer-hidden-getter`). gencs's subclass has its own set-only indexer, so its C#
  does not compile: `CS0154: The property or indexer 'Sub.this[int]' cannot be used in this context because
  it lacks the get accessor`.
- A generic class with array access gets the companion indexer it can implement
  (`haxe-generic-class-get-only-indexer`, `haxe-generic-class-int-indexer`): a get-only one when it has no
  `__set`, none when DCE removed its `__get`, and a single one where its `__get` and `__set` mention no
  type parameter, so that the companion declares them too. gencs's companion always declares `object this[int key] { get; set; }`, so its C# does not
  compile: `CS1061` for the missing `__set`, `CS0535` for the missing implementation, and `CS0111: Type
  'IVec' already defines a member called 'this' with the same parameter types` where the companion also
  declares `__get` and `__set`.
- Member order of events' private members and the Field table: hxc writes the methods in gencs's order (entry point,
  `.cctor`, constructors, static events' accessors, `__hx_ctor_*`, statics, instance events' accessors, properties,
  the instance members; a static `@:property` var's accessors are among the statics in declaration order), except
  three things (`member-order-event-members-and-fields-differ-from-gencs`, with gencs's run in its header).
  - The private bodies `_add_X` and `_remove_X` of a custom (non-field-like) event are in their Haxe declaration
    position in hxc, where gencs writes them later: a static event's after the statics, an instance event's after
    the reflection members and before `ToString`, the events in reverse declaration order and each pair as
    `_remove_X`, `_add_X`.
  - The backing field of a field-like event is in declaration order in hxc, where gencs puts it ahead of the other
    fields of its kind (instance or static).
  - gencs's Field table lists the static fields first and puts a generic class's `__hx_init_called` first; hxc lists
    the instance fields first and `__hx_init_called` last. `GetFields` does not show this (the CLR lists instance
    fields first), `FieldInfo.MetadataToken` order does.
  Only reflection's enumeration of non-public members and metadata tokens see these.
- A `@:struct` with no instance fields: Roslyn gives gencs's struct a ClassLayout row of size 1, and hxc
  writes no row. The runtime sizes both at 1 byte, so only metadata sees it: `Type.StructLayoutAttribute.Size`
  is 1 for gencs's struct and 0 for hxc's. hxc keeps this so that a DLL without explicit layout is unchanged
  by 4c's pseudo-attributes.
- A `@:nativeGen` method or constructor with optional arguments: hxc gives each of its optional-argument
  overloads, and the full method, the field's attributes once (`attrs-nativegen-optional-overloads-attributes`).
  gencs writes the field's attributes in front of the first overload, which then has them twice and the full
  method none, so its C# does not compile for an attribute without `AllowMultiple`: `CS0579: Duplicate
  'System.ComponentModel.DescriptionAttribute' attribute`. With `AllowMultiple` it compiles, and reflection
  sees two copies on the first overload and none on the full method, where hxc writes one on each
  (`attrs-nativegen-optional-overloads-allow-multiple`, whose `[gencs]` section shows gencs's counts).
- `haxe.lang.Null<T>` has gencs's `op_Implicit(T)`, `_ofDynamic` and `initonly` `value` and `hasValue`, but not
  its nested `__NoValue__` class and the `op_Implicit(__NoValue__)` conversion (`null-struct-csharp-surface`,
  `null-struct-csharp-metadata`, `null-implicit-from-csharp`). C# `Null<int> x = null` compiles against gencs's
  DLL and not against hxc's; nothing real writes it, and C# code that passes a `bool` to a Haxe `?b:Bool`
  parameter works in both. Reflection sees one `op_Implicit` and no nested type, where gencs's shows two and
  `__NoValue__`. hxc keeps its extra public `toString()`, the method `ToString` calls.
- `initonly` is written on `haxe.lang.Null<T>`'s two fields and on no other `@:readOnly` or `final` field. gencs
  marks 14 more in the runtime, which the server's DLL shows: `Math.PI`, `NaN`, `POSITIVE_INFINITY`,
  `NEGATIVE_INFINITY` and `rand`, `Date.epochTicks`, `Sys.epochTicks`, `Type.__createEmptyInstance_EMPTY_ARGS`,
  `haxe.lang.Enum._hx_index`, `FieldHashConflict.hash` and `name`, `GenericInterface.generic`,
  `Runtime.undefined` and `StringExt.empty`. Only reflection (`FieldInfo.IsInitOnly`) sees it, and nothing real
  reads it.
- The assembly carries `TargetFramework`, `@:cs.assemblyMeta` entries and the attributes Haxe code writes, and not
  what the SDK and Roslyn add to gencs's build: `AssemblyCompany`, `Configuration`, `FileVersion`,
  `InformationalVersion`, `Product`, `Title`, `CompilationRelaxations`, `RuntimeCompatibility(WrapNonExceptionThrows)`,
  `Debuggable` (milestone 5, with `-D dotnet-debug-jit`), the module's `RefSafetyRules` and `UnverifiableCode`, the
  DeclSecurity row and `<PrivateImplementationDetails>`, nor `DebuggerBrowsable(Never)` on a `@:property` var's
  backing field (a Debug-configuration artefact of gencs's build). Reflection and tooling read them; hxc never throws
  a value that is no `Exception`, so `WrapNonExceptionThrows` changes nothing.
- hxc writes more closure classes than gencs (3,759 against 2,251 in the server app). Every name gencs writes is
  there; the others are local functions that gencs does not have a class for, such as a predicate passed to
  `Array.filter` on an `Array<Dynamic>` or on an array of a type parameter, `Array<T>` or `Array<Null<T>>` (hxc's
  `map` and `filter` inline on any other array, as gencs's do, with no closure allocated on the plain path; the class
  stays for the call on a forwarding array, which an ordinary
  array never reaches), and the `_Fun_N` numbering that follows. Only reflection over the assembly's types sees them.
- hxc writes one more class than gencs per method of a Haxe class used as a value, a `haxe.lang.ClosureInvoker` named
  `<Class>_<method>__Invoke`, and `haxe.lang.Closure` has more members than gencs's: a protected field `__hx_invoker`,
  the public method that sets it, `__hx_setInvoker`, and its own `__hx_invoke<N>_o`/`_f` for up to 5 arguments, which
  call the method directly when the arguments already have its parameters' types and an instance method's receiver is
  of its class (`method-value-direct-shapes`, `method-value-instance-direct`). Only .NET reflection over the runtime
  type or the assembly's types sees them, as `Reflect.fields(f)` and `Reflect.field(f, "__hx_invoker")`, which read public fields, and `Type.getInstanceFields(Type.getClass(f))`, which
  leaves out `__hx_` names, show no change (`method-value-identity`). `Reflect.field(f, "__hx_setInvoker")`, a name no
  program has a reason to ask for, finds the method, as `Reflect.field(f, "__hx_invoke1_o")` already does in gencs.
- The frames of a method value that went direct hold the invoker's and `Closure`'s frames instead of the reflection
  and runtime ones (`callField`, `__hx_invokeDynamic`, `callMethodCasting`, ...), in `haxe.CallStack`,
  `Exception.details()` and `Exception.StackTrace` text. The invoker catches what the method throws and throws it again
  with IL `throw`, as `Runtime.callMethodCasting` does with the `InnerException`, so the exception's trace starts at
  the same place for the program: the method's own frame is in neither path's `Exception.StackTrace`, nor in the
  `Exception.stack` of a native exception. The `Exception.stack` of a Haxe `throw`, taken when the exception is made,
  has it on both. The exception's type and message, and the program's own Haxe frames and their order, stay the same
  (`method-value-throws`).
- The by-name path of an instance method has no reflection: it is the `__hx_invokeField` of the receiver's class, whose
  case calls the method and keeps its frame, so that method's invoker catches nothing, and the frame that goes is that
  `__hx_invokeField`, a generated member of the program's class. The case of a class that overrides the method and has
  a method of its own is `Runtime.slowCallField`, reflection as above, so when the receiver is of such a class the
  invoker throws again and unboxes a `Dynamic` result, as for a static (`method-value-instance-throws`,
  `method-value-instance-results`). A class that overrides it and has no method of its own has no `__hx_invokeField`,
  so a superclass's case calls the override. Stay by name: a method with such an override that is a `toString` (by name
  the receiver's `ToString`), or whose override is in a generic class or a standard-library class
  (`method-value-instance-std-override`); a method whose name a member of a class in its line also has, an `@:overload`
  or a member with that `@:native` name, as by name that member may be found (`method-value-instance-by-name-rivals`);
  and a `@:compilerGenerated` method, which by name is not found (`method-value-instance-by-name-shapes`).
- From the second call on of a method called by name through reflection, .NET's reflection frames have no declaring
  type, and reading them throws `NullReferenceException`: in `haxe.CallStack.callStack()` in the method, and in `e.stack` and `e.details()`
  in a catch of an exception the method made with a Haxe `throw`. gencs's by-name calls and hxc's do, and a call that
  goes direct does not. A native exception's `e.stack` and `e.details()` do not, as its reset trace has no such frame.
- A resource name with a non-ASCII character or a `\` is found by `haxe.Resource` in hxc
  (`resource-non-ascii-name`, `resource-backslash-name`). gencs escapes the name's UTF-8 bytes into the file
  name (`é` is `-x195-x169`) and turns `\` into `-x92`, where `haxe.Resource` escapes the UTF-16 code units at
  run time (`é` is `-x233`) and keeps `\`, so under gencs `listNames()` lists the name and `getString` returns
  null. hxc names the manifest resource the way the runtime looks it up, so `GetManifestResourceNames()`
  differs from gencs's for those names only. A name outside the BMP is two code units at run time and four
  UTF-8 bytes in gencs, the same divergence (`resource-astral-name`: `U+1F600` is `-x55357-x56832` in hxc,
  `-x240-x159-x152-x128` in gencs).
- Two resource names that escape to one manifest name are a compile error in hxc (`dotnet: the resources "{" and
  "\x0c3" would both be the manifest resource src.Resources.-x123`; `resource-escape-collision-is-an-error` for the
  macro form, `resource-escape-collision-on-command-line` for `-resource`). The names are positionless, since a
  `-resource` is a command-line argument. gencs writes one file over the other, and csc says CS1508 for
  duplicate resources, so neither has the error. The easiest collision to meet is a low code point and a digit
  against a larger one: `a!5` (`!` is 33) and `a` + U+014F (335) are both `a-x335`, but gencs's UTF-8 byte escape
  would write the second as `a-x197-x143`, so there it is no collision. The `-resource` case uses `{` against
  form feed + `3` instead, because the compiler reads its command line in the ANSI code page on Windows and U+014F
  arrives as `o`.
- hxc does not refuse access to the `cs` package while a macro runs, where Haxe's typer says "You cannot
  access the cs package while in a macro". A macro that names `cs.*` types compiles in hxc and fails in Haxe,
  so a program can pass hxc and not Haxe. This is a typer difference, not a resource one; the resource case
  `resource-expression-macro` wraps `main` in `#if !macro` for gencs and is accepted either way.
- Events defined in Haxe (`@:event` vars): the cases where gencs's C# fails to compile are `dotnet:` errors in
  hxc that quote the C# error, and the cases where gencs builds and runs differently are listed with what it does.
  - An instance event of an hxgeneric class (`event-generic-class-is-an-error`): the accessors would implement the
    members of the class's companion interface, and gencs's C# does not compile: `CS0686: Accessor
    'G<T>.Changed.add' cannot implement interface member 'G.add_Changed(EventHandler)' for type 'G<T>'. Use an
    explicit interface implementation.` A `@:nativeGen` generic class has no companion, and a static event needs
    none, so both are written (`event-nativegen-generic-class`, `event-field-like-nativegen-generic`).
  - An event of a generic interface (`event-generic-interface-is-an-error`): the add_ and remove_ that mention no
    type parameter are its companion's, and gencs fails with an internal error in `partition` (gencs.ml:2822,
    "Filters.check_cs_events makes sure methods are present"). hxc refuses.
  - A Haxe override of an event's add_ or remove_ (`event-override-accessor-is-an-error`): gencs makes the base
    method the event's private `_add_X`, so the override has nothing to override: `CS0115:
    'Sub.add_Changed(EventHandler)': no suitable method found to override.`
  - Reading or assigning the var of a custom event (`event-read-is-an-error`, `event-write-is-an-error`,
    `event-static-read-is-an-error`): `CS0079: The event 'A.Changed' can only appear on the left hand side of += or -=`.
    So is a custom event's initializer, static or not (`event-static-initializer-is-an-error`,
    `event-instance-initializer-is-an-error`): gencs writes it as an assignment in the (static) constructor.
  - Assigning an init-only property of a .NET class (`netlib-modreq-members-are-refused`): `CS8852: Init-only property
    or indexer 'Box.I' can only be assigned in an object initializer, or on 'this' or 'base' in an instance
    constructor or an 'init' accessor`. Haxe has no object initializer, so hxc refuses every call of the setter
    (a Haxe subclass's constructor writing `this.I` is the one assignment C# allows and hxc refuses).
    Reading or assigning a field-like event's var anywhere but its own class, a subclass, another class and a local
    function's class included (`event-field-like-outside-class-is-an-error`): `CS0070: The event 'A.Changed' can only
    appear on the left hand side of += or -= (except when used from within the type 'A')`. Inside its class the var
    is the backing field in both.
  - An event type that is no delegate (`event-non-delegate-type-is-an-error`): `CS0066: 'A.Changed': event must be of a
    delegate type`.
  - A class implementing an interface's event with a plain var of that name, Haxe interface or .NET
    (`event-interface-plain-var-is-an-error`, `netlib-event-var-not-event-is-an-error`): `CS0535: 'Plain' does not
    implement interface member 'IPing.Ping'` and `CS0470: Method 'Plain.add_Ping(EventHandler)' cannot implement
    interface accessor 'IPing.Ping.add' for type 'Plain'. Use an explicit interface implementation.`
  - A `@:protected` var implementing an interface's event, Haxe or .NET
    (`event-protected-implementing-interface-is-an-error`, `netlib-event-protected-implementing-is-an-error`): its
    accessors are Family and the CLR would not load the type. gencs's C# fails: `CS0737: 'Q' does not implement
    interface member 'IPing.Ping'. 'Q.Ping' cannot implement an interface member because it is not public.` The same
    C# error is given for `@:private` and `@:internal`, which hxc ignores on every member, so there the event is
    public and works (`event-private-implementing-interface-is-ignored`).
  - Reading or assigning an interface's event var (`event-interface-var-read-is-an-error`): `CS0079: The event
    'IPing.Ping' can only appear on the left hand side of += or -=`.
  - A field-like event in an explicit-layout struct (`event-field-like-in-explicit-layout-struct-is-an-error`) is
    `CS0625: 'Overlay.Changed': instance field in types marked with StructLayout(LayoutKind.Explicit) must have a
    FieldOffset attribute` in both; an event carries no attribute in gencs, so the field cannot be given one.
  - Under `-dce full` hxc keeps an event's var, `add_X` and `remove_X` together (`event-dce-full-unread-var`,
    `event-dce-full-static`, `event-dce-full-field-like`; `event-dce-full-keep` for `@:keep`). For an interface's
    event gencs's C# fails with `CS0501: 'IPing._add_Ping(EventHandler)' must declare a body because it is not marked
    abstract, extern, or partial` (`event-dce-full-interface`). Haxe's own rule keeps
    the methods only when the var is `@:keep`, and DCE removes a var Haxe code never reads, so gencs writes no event and
    renames the surviving method to `_add_X`: its C# does not compile, `CS1061: 'A' does not contain a definition for
    'add_Changed' and no accessible extension method 'add_Changed' accepting a first argument of type 'A' could be
    found`. In hxc the event is there, and its handlers are called.
  - One empty body (`event-one-empty-body`): gencs takes the event's kind from whichever of add_ and remove_ is declared
    first, so with the empty one first it writes a field-like event and silently drops the other body (its run prints
    `done` and not `add body`). hxc makes an event field-like only when both are empty, so the body runs.
  - hxc hides every `@:event` var from reflection and writes no attribute on an event, as gencs does (gencs adds
    `@:skipReflection` to all of them, Haxe's own check only to `(default, default)` ones), so a `@:meta` on the var
    is dropped (`event-meta-on-var-is-dropped`, `event-haxeui-builder-vars-are-not-events`); the attributes of a
    custom event's add_ stay on its private `_add_X`, and those of a field-like event's methods are dropped with them.
- An `f` literal in inline C# whose double is exactly halfway between two floats is a compile error in hxc
  (`inline-cs-float-literal-midpoint-is-an-error`: `hxc cannot round this float literal as C# does; write it with
  fewer digits`). Roslyn rounds the decimal to a float once, so `(double)1.0000000596046447753906250001f` is
  1.0000001192092896 and the exact midpoint `1.0000000596046447753906250000f` is 1 (round to even). hxc reads the
  literal as a double first, which would give 1 for both, a silent wrong value; telling the two apart takes the
  literal's exact decimal value, so hxc refuses every literal that lands on a midpoint, `16777217f` too, which Roslyn
  rounds right. Every other `f` literal, an exactly representable one included, rounds once and agrees with C#
  (`inline-cs-float-literal-rounding`, which is `@gencs`). No inline C# in the apps has a float literal.
  A literal that rounds to infinity is refused too (`inline-cs-float-literal-out-of-range-is-an-error`): C#'s
  error is `CS0594: Floating-point constant is outside the range of type 'float'`, and the text says so. The
  midpoint between `float.MaxValue` and 2^128 rounds up, so it is out of range, and a literal just below it whose
  double equals it is refused with it, where Roslyn would accept it.
- Two metadata-only differences in a class's InterfaceImpl rows, which no runtime check sees. The rows are in another
  order than Roslyn writes them, and an `hxgeneric` class has no InterfaceImpl row for `haxe.lang.IHxObject`, where
  Roslyn lists the closure of its interfaces. `is`, `Type.GetInterfaces()` and casts
  agree with gencs's DLL. With `-D dotnet-nullable`, the missing row can move a tied nullable-context count, but the
  rows stay consistent with each other, so `NullabilityInfoContext` reads the same.

## Left to the builder

- Internal module layout under `src/hxc/codegen/` (e.g. a `dotnet/` folder next to `jvm/`), and how
  much of the JVM backend's lowering is shared or copied.
- IL lowering strategy for Haxe's expression-oriented constructs.
- An IL size pass after milestone 4, when the server app first builds and its method sizes can be
  measured. Milestone 2 always emits long-form branches, never fuses a comparison into its branch
  (`bne.un`, `ble`, …), and lowers `switch` to a chain of comparisons. The JIT folds those back, but
  IL size decides what it inlines (a callee of 16 bytes or less always is), so shorten branches,
  fuse comparisons or emit `switch` tables only where small methods are pushed over. No benchmark
  gates it (see Non-goals).
- How the differential tests plug into hxc's existing harness (`src/hxia/harness`,
  `tests/divergences.json`).
- PDB extras (embedded source, Source Link).
- Which the server app build variants (`Server_Core`, `Server_Reports` in Builder.hx) come after the main
  `Server` build.
- Builder.hx changes in the server app to call the new generator and drop the `HaxeServer.csproj` compile and
  text patches (to be done in the server app's repository, separately). Its `#nullable enable` patch becomes
  `-D dotnet-nullable=ai.tools` (4c ruling 2), passed where Builder.hx patches today, and its server hxml gains
  the two `-resource` lines for the coach and tutorials files (4c ruling 8): owner changes, listed with the others
  in milestone 4's 4c bullet.
