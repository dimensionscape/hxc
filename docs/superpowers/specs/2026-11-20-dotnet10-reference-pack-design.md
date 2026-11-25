# --dotnet on the .NET reference pack, phase 1: design

2026-11-20. Follows the change that made hxcs optional (8cae47cd) and a throwaway spike on the branch
`spike/dotnet10-refs` (worktree `.claude/worktrees/dotnet10-spike`, uncommitted).

## Intent

Today both `--cs` and `--dotnet` type a program against hxcs's reference assemblies: Mono's .NET 2.0–4.5
`mscorlib.dll`, `System.dll` and `System.Core.dll`, now carried by hxc itself. Haxe code can only call what
those 2009–2016 assemblies declare, and every `--dotnet` output references `mscorlib` 2.0.0.0, which .NET 10
forwards to its own libraries.

The goal is that Haxe code built with `--dotnet` can call the .NET 10 (or later) framework: `System.Text.Json`,
`HttpClient`, `System.Threading.Channels`, the newer collections, and in later phases `Span<T>`, generic math
and the rest. Phase 1, this document, makes `--dotnet` type against the .NET SDK's reference pack and makes
everything that works through ordinary classes, methods and generics callable. Phase 2 adds, one feature at a
time, what Haxe cannot express today.

### Why

- **Simplification, and Haxe has moved on.** Haxe no longer maintains hxcs or its C# target. hxc's `--dotnet`
  is its own target with no gencs output to match, so it need not stay on gencs's reference assemblies.
- **Modern APIs.** The person driving this wants both a modern reference set and the ability to call .NET 10
  APIs from Haxe. They named no first API; the API checks below are my picks.

## What the person driving this decided

- `--cs` (including `--cs -D dotnet`) keeps the Mono reference assemblies; `--dotnet` moves to the reference
  pack. They are split by the flag.
- Two phases: phase 1 is this document; phase 2 brings the left-out features one by one, `Span<T>` and
  `ref struct` types first, then static abstract interface members, then `ref` returns and `scoped`
  parameters. Each phase-2 feature gets its own design.
- What Haxe cannot express is **left out per member and listed under a define**, not given a weakened type
  and not failing the whole type.
- hxc's own .NET host stays on the Mono references during phase 1.
- .NET optional parameters become optional on the Haxe side in phase 1 (proposed with the design, accepted).

## Goals

1. `--dotnet` reads the reference pack for `-D dotnet-version` (default 10):
   `<dotnet root>/packs/Microsoft.NETCore.App.Ref/<N>.0.<highest patch>/ref/net<N>.0`, every DLL in it, as
   std. The output references `System.Runtime`, `System.Text.Json` and so on at `<N>.0.0.0`.
2. Every member of those assemblies is either callable, refused at its call with a compile error (as today:
   volatile fields, init-only setters, `modreq`/`in` parameters of virtual methods, …), or left out and listed
   with its reason by `-D dotnet-netlib-report`. Nothing is dropped without one of the three.
3. The whole std (`tools/stdall.sh`'s include set) builds with `--dotnet`, with no more stubs than with
   `--cs -D dotnet`.
4. These run correctly with `--dotnet`: `System.Text.Json` (`JsonSerializer.Serialize`/`Deserialize` of a
   `Dictionary`, `JsonDocument.Parse` and property access), `HttpClient` constructed and configured (no
   network), `System.Threading.Channels` (create, write, read), `PriorityQueue`, `HashSet`,
   `ConcurrentDictionary`.
5. A parameter of a non-virtual .NET method or constructor that C# lets a caller leave out is optional in
   Haxe, and leaving it out passes the value C# would pass. `JsonSerializer.Serialize(d)` compiles and picks
   the overload C# picks.
6. Inherited members of a generic base class instantiated with repeated or reordered parameters
   (`Channel<T> extends Channel<T, T>`) are referenced correctly, on both reference sets.
7. `--cs` builds are unchanged: the same bytes for every existing case.

## Non-goals

- Phase-2 features: calling members that take or return `Span<T>`/`ReadOnlySpan<T>` or any other
  `ref struct`, static abstract members and generic math, `ref` returns and fields, function pointers.
- Moving hxc's own .NET host to the reference pack.
- Optional parameters for `--cs`. The Mono path keeps Haxe's behaviour (every parameter required), so it
  stays comparable with gencs.
- NuGet packages, or any reference set other than the SDK's pack and `--net-lib`/`--net-std`.
- Language-level additions (named arguments, `params` call syntax beyond what exists).

## Anti-goals

- **A call that compiles and then fails or misbehaves at run time** because of a type hxc approximated. A
  member is either expressed faithfully or left out. (This is why members using `ref struct` types are left
  out in phase 1 even though the spike converted them.)
- **Any change to `--cs` output**, or to hxc's own build of itself.
- **Silent loss**: a member left out without a way to see it.
- A noticeably slower `--dotnet` build: the spike measured about +0.15 s on hello-world for reading the pack's
  167 DLLs (the light reader indexes them; whole tables are read only for converted classes).

## Constraints

- The .NET SDK (not only the runtime) must be installed for `--dotnet`; a missing pack is a compile error
  that names the version and says to install the SDK.
- hxc's assembly reader and converter are a port of Haxe's netlib loader; Haxe 4.3.7 fails on the .NET 10
  pack exactly as hxc did (`Type not found : T0`). Phase 1 takes the reader beyond Haxe.
- The C# std (`std/cs`) and hxc's runtime copy (`src/hxc/codegen/dotnet/runtime`) must type on both reference
  sets.
- Outputs stay deterministic: the pack's assemblies keep `<N>.0.0.0` across patches, so the installed patch
  does not change the output (already true for `NetRefs`).

## Approaches considered

1. **Leave out per member, list under a define (chosen).** Safe: what is callable works; phase 2 shrinks the
   list. The spike needed only a few rules to get the std and the API checks through.
2. **Weaken types instead of leaving members out** (an unbound class type parameter becomes `Dynamic`, a
   `ref` return becomes a value). More members callable, but some calls would compile and then fail at run
   time — the anti-goal. Not taken.
3. **Fail on the whole type** (Haxe's behaviour). `String` itself fails, through `IParsable<T>`. Not
   possible.
4. **Retarget only**: keep typing against Mono and rewrite the output's references to `System.Runtime`.
   Gains nothing callable. Not taken.

## Spike evidence

On the spike compiler, with `--dotnet` reading the 10.0.14 pack:

- hello-world, the empty program and the whole std (`stdall.sh` with `--dotnet`) build; the std has the same
  single stub (`cs.Pointer.add`) as on the Mono references.
- JSON, the collections and `HttpClient` run with the expected output.
- Channels compiles, passes ILVerify and throws `BadImageFormatException`: `get_Writer`'s MemberRef parent is
  `Channel`2<int32, !1>` instead of `Channel`2<int32, int32>` (goal 6).
- Left out in the API program: 176 static abstract interface members, 9 `ref` returns.
- `JsonSerializer.Serialize(d, null)` is an ambiguous overload (goal 5).

What the spike changed, which phase 1 does properly:

- `NetConverter.convertIlmethod`: static methods erase class type parameters (`changeSig`), but the `ref`/`out`
  argument branch skipped it, leaving `T0` unbound. A Haxe bug; fixed for both reference sets.
- Static abstract/virtual interface methods left out.
- `ref` returns on methods and properties, and `ref` fields, left out (they mapped to `cs.Pointer`, whose
  module is an `#error` without `-D unsafe`).
- An indexer returning by `ref` no longer makes the class implement `ArrayAccess` (Span became
  `ArrayAccess<cs.Pointer<T>>`).
- `runtime/sys/io/File.hx` passed bare `Open, Read, ReadWrite` to `FileStream`; with .NET 10's larger
  overload set they no longer resolved. The spike qualified them.

## How it gets made

### Selecting the reference set (decided)

- `--dotnet` sets an internal define (my call: `dotnet_refpack`, not listed in `--help-defines`) and no longer
  adds `-lib hxcs`. `--cs` and `--cs -D dotnet` are unchanged.
- `NetSetup.beforeGenerate` with that define and no `--net-std`: every `.dll` of `NetSetup.referencePack(ctx)`,
  sorted ignoring case, becomes `ctx.netStdFiles`. With `--net-std`, `--dotnet` keeps today's digraph lookup
  (an escape hatch; my call).
- Defines with the reference pack (my call, from the spike): `net_ver=50`, `NET_20` … `NET_50`,
  `net_target=netcore`, `netcore`. The std branches only on `net_ver < 35`. The builder checks that no other
  std or runtime code reads these in a way that matters.
- README: `--dotnet` and `--cs -D dotnet` are no longer the same build; the table rows and the ".NET output"
  section say which references each uses and that `--dotnet` needs the SDK.

### Leaving members out (decided rules; the report format is my call)

The rules below apply in a reference-pack build (`--dotnet` without `--net-std`) to every assembly it
converts, `--net-lib` DLLs included. A Mono-reference build (`--cs`, `--cs -D dotnet`, `--dotnet --net-std`)
converts exactly as today; the only change there is the `ref`/`out` erasure fix, which only turns a former
`Type not found : T0` into a working conversion. So the existing case `netlib-modreq-members-are-refused`
(a `ref` return under `--cs -D dotnet`) keeps its current error.

A member is left out, with its reason, when:

1. it is a static abstract or static virtual member of an interface;
2. it returns by `ref` (method or property), or is a `ref` field;
3. its signature mentions a byref-like type (a type carrying `IsByRefLikeAttribute`: `Span<T>`,
   `ReadOnlySpan<T>`, `Utf8JsonReader`, …), in a parameter, return, field or property type, at any depth;
4. its signature contains a function pointer;
5. (existing) it uses unmanaged pointers without `-D unsafe`.

At type level:

- A byref-like type is **not converted at all** in phase 1: writing its name is `Type not found`. Haxe cannot
  keep a value of one within the runtime's rules (no closures, no `Dynamic`, no fields of ordinary classes,
  no type arguments), so it gets no constructor, member or name until phase 2 designs them. Rule 3 finds
  these types by the attribute on their definition, without needing a Haxe type for them.
- A ref-returning indexer adds no `ArrayAccess`.
- A Haxe class that extends a .NET class, or implements a .NET interface, with an abstract member that was
  left out is a compile error naming that member (it could only fail to load). The same for a static
  abstract interface member: implementing `INumber<T>` and the like is refused in phase 1.

`-D dotnet-netlib-report` prints one line per member the converter drops, after the compile, sorted and
deduplicated, as `-D dotnet-stub-report` does: `left out <Type>.<member> <signature>: <reason>`. It covers
rules 1–5 and the converter's existing drops that lose a callable member (a method sharing its name with a
field, a property already declared). Exact-duplicate overloads are not listed: nothing is lost. Members refused
at a call site are not listed either: they are compile errors already, not silent. Only members of classes
that were converted are listed (the light reader means unconverted classes are never examined). In a
Mono-reference build the report lists the existing drops only. A value narrows it:
`-D dotnet-netlib-report=<prefix>[,<prefix>…]` lists only lines whose .NET type name starts with one of the
prefixes (`=packlib`, `=System.Text.Json`), since a whole program's report is dominated by the framework's
generic-math interfaces.

### Optional parameters (decided for `--dotnet` only)

A parameter `ExternMembers.canOmit` accepts (a default value, `[Optional]`, or a trailing `params` array; never
`ref`/`out`) becomes an optional Haxe argument (`?name`) in the converted extern, with the reference pack only,
and only on static methods, constructors and non-virtual instance methods. Virtual, abstract and interface
methods keep every parameter required, so a Haxe override or implementation never has to match optional
flags, and a Haxe body never receives a padded argument (`Stream.ReadAsync(…, CancellationToken)` still
takes its token).

Which arguments were left out is decided in the **typer**, not guessed by the generator: the C# platform pads
omitted arguments with `null` (`padNulls`), which the generator cannot tell from a `null` the user wrote. For
calls to these .NET members the typer marks each padded argument as omitted (trailing or skipped in the
middle). At an omitted argument the generator passes what C# passes: the constant default (`a.constant`), the
`[DefaultParameterValue]`/`pdefault` value, `null` for a reference type, `default(T)` for a value type, and an
empty array for `params`. An argument the user wrote is passed as written, as in C#: an explicit `null` to a
reference-type parameter is `null` even where the default is `"dflt"`. A value-type parameter cannot take
`null`, so a literal `null` there counts as omitted; a non-constant `Null<T>` value there is converted as Haxe
converts `Null<T>` to `T` anywhere (ordinary Haxe semantics, not a new approximation).

Overload resolution keeps Haxe's rules. They already hold C#'s tie-break for optional parameters
(C# 12.6.4.3; `F(int)` over `F(int, int b = 0)` for `F(1)`): `Overloads.reduceCompatible` keeps the matching
candidates with the fewest optional parameters before it rates conversions, so this needs no new code, only a
case. Haxe applies it earlier than C# does (`F(long, long)` beats `F(int, int b = 0)` for `F(1, 2)`, where C#
picks the `int` one); that difference is recorded, not changed. Nothing else of C#'s rules is taken in phase
1; an ambiguity stays a compile error. The builder
checks `JsonSerializer.Serialize(value)` picks `(TValue, JsonSerializerOptions)` as C# does, and records in
this document any call in the goal-4 checks where Haxe's pick differs from C#'s.

### The generic base bug (decided: fix in the generator)

The MemberRef parent for an inherited member is built from the declaring class's own type parameters instead
of substituting the instantiation down the chain. `ExternMembers.chainFrom` substitutes correctly; the builder
finds where the MemberRef parent is built for a Haxe-typed call on an inherited extern member (the
`TypeFunctions.applyParams` path in `ExternMembers` around the super chain is a candidate) and fixes it.
Covered by a `--net-lib` fixture class `Pair<A, B>` with a member, a subclass `Same<T> : Pair<T, T>` and a
`Swap<A, B> : Pair<B, A>`, on both reference sets.

### Bare enum values against larger overload sets (investigate, then decide)

`new FileStream(path, Open, Read, ReadWrite)` stopped resolving with .NET 10's overloads. The builder finds out
whether hxc's overload resolution here differs from Haxe 4.3.7's (reproduce with an `--net-lib` fixture that
adds same-arity overloads to a Mono-era signature, and compare with Haxe). If hxc differs, fix the typer to
match Haxe; if Haxe behaves the same, qualify the values in hxc's runtime copy (and keep Haxe's std untouched).

### hxc's own .NET host (decided)

`tools/dotnet-host/build.sh` builds with `--cs <dir> -D dotnet` instead of `--dotnet <dir>`, so it stays on
the Mono references. The builder confirms the output is byte-identical to today's and the CI bootstrap check
still passes.

### Tests (my call; the builder adds cases as needed)

- `tests/dotnet/run.sh`: `@dotnet-flag` already selects `--dotnet`; those cases now run on the pack, and
  their expected dumps are updated where assembly scopes change (`[mscorlib]` → `[System.Runtime]`). A new
  tag is unnecessary.
- New `@dotnet-flag` cases: the goal-4 API checks (each prints what it checked), the optional-parameter rules
  (each default kind, an explicit `null` against a non-null default, a skipped middle argument, the
  fewer-omitted tie-break, a virtual method staying required), `Same`/`Swap` from the fixture, a left-out
  member reported by `-D dotnet-netlib-report` and refused at a call as an unknown field, `Span` as
  `Type not found`, extending a class with a left-out abstract member refused, and the missing-pack error (by
  pointing `DOTNET_ROOT` at an empty folder).
- `tools/stdall.sh` takes an optional flag to build with `--dotnet`; the plan runs both.
- All existing cases keep passing with unchanged bytes (goal 7).
- CI's `.NET` job already installs the .NET 10 SDK, so the pack is there.

## What the builder decides

Internal names (the define, helper functions), the report's exact wording, where in the converter the rules
live, how byref-like types are detected (attribute lookup per type, cached), how call sites materialize each
default value, case names and fixtures, and any further left-out rule the std or the API checks turn up (each
added to the report's reasons and to this document's list).

## Exit

- Goals 1–7 hold, with the cases above passing on the native and the .NET host.
- `stdall.sh` with `--dotnet`: exit 0, stubs equal to the `--cs -D dotnet` run.
- `-D dotnet-netlib-report` on the API program lists only rules 1–4 and the existing drops named above.
- The .NET suite (all cases), hxc's own conformance cases and `cs-target` pass; the .NET host still builds
  itself to the same bytes.
- hello-world with `--dotnet` builds within 0.3 s of `--cs -D dotnet` (pinned, best of 3).
- A short note in this document's "Spike evidence" style records what phase 1 measured, and the phase-2
  list is updated with what the report shows most often in the API checks.
