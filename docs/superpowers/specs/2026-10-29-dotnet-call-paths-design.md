# .NET faster call paths: inline map/filter, direct method closures, typed reflection calls — design

Date: 2026-10-29
Status: ready for review by the person driving this

This extends `docs/superpowers/specs/2026-10-21-dotnet10-il-generator-design.md` (the main spec) and
sits on top of milestone 5 (`2026-10-29-dotnet-portable-pdb-design.md`). Where this document is more
specific it wins; where it is silent, those decide.

## Intent

Make the code hxc's `-D dotnet` backend writes run faster, with no change in what any program does.
There is no reported slow spot: the person driving this wants the speed for its own sake. A survey
picked the targets.

### Why these three

A 34-benchmark program, compiled by hxc and by Haxe 4.3.7's gencs + Roslyn (Release), timed with the
two builds interleaved (best of 15 runs each; both builds give the same checksum on every benchmark):

- hxc is at parity or faster on 31 of 34, 2–6× faster on arrays, virtual/interface calls, enum
  switches, `Std.isOfType` and `StringMap`.
- Three call paths are slow:

| benchmark | gencs | hxc | cause |
|---|---|---|---|
| `a.map(x -> x * 2).filter(x -> x % 3 == 0)` | 3.0 ms | 24.0 ms (7.9×) | hxc's runtime `Array.map`/`filter` are not `inline` (Haxe's own C# std's are) |
| `twice(inc, s)` (a static method as a value) | ~425 ns/call | ~440 ns/call | both builds call it by name through .NET reflection |
| `Reflect.field(p, "x")` / `setField` on a `Point` | 5.1 ms | 10.8 ms (2.1×) | hxc calls Runtime's `Dynamic` overload where C# picks the `HxObject` one, and boxes the Float result |

Facts the survey established, which the design relies on:

- gencs's 3 ms comes from Haxe inlining `map`/`filter` *and the lambda passed to them* into a plain loop.
  **hxc's front end already does the same substitution** for an inline function with a function-literal
  argument (checked: `inline function app(f:Int->Int, x) return f(x)` called as `app(x -> x * 2, k)`
  compiles to a `mul`, with no closure class; with `f` also passed to a method on another branch, the loop
  still substitutes it and the closure is made only on that branch).
- **`Array<Dynamic>` must not inline** (found while planning). Its static type is the non-generic
  companion, so an inlined body would reach `length`, `__hx_fwd` and `__unsafe_get` by name for every
  element, far slower than today's one by-name `map` call. The main spec also records `map`/`filter` on a
  typed array held as `Array<Dynamic>` as working where gencs's inlined loops throw
  `InvalidCastException` (case `companion-array-map-filter`), which stays. A run-time test cannot separate
  it from `Array<Point>` (both are ``Array`1<object>``), so the typer decides: one small rule in
  `typing/Inline.hx`, keyed on a metadata only hxc's runtime `Array` uses, so no other target changes. The
  same holds for a `map` whose result is `Array<Dynamic>`, as the inlined `ret` would be the companion. Haxe
  does not bind a monomorph to `Dynamic` on unify, so a callback that returns `Dynamic` (or `null`) leaves
  the result's type argument an unbound monomorph at the call, which defaults to `Dynamic` only later: that
  counts as `Dynamic` too. A type parameter, `T` or `Null<T>`, counts too: the lambda's boundary converts a
  Dynamic value to the `T` by `Runtime.genericCast`, and an inlined body in hxc would not.
- The second row is the largest cost in the program, and gencs has it too: `new Closure(typeof(P),
  "inc", hash)`, then `VarArgsBase.__hx_invoke1_f` → `__hx_invokeDynamic` → `Runtime.callField` →
  `Type.InvokeMember`. A method of a Haxe *instance* as a value takes `__hx_invokeField`'s string-hash
  switch with an `object[]` of boxed arguments: cheaper, still slow.
- IL tidying (short branches, fused compare-and-branch, `switch` tables) was measured and left out:
  loops in hxc's IL shape and Roslyn's run at the same speed, and tiered PGO inlines even hxc's larger
  methods.

The benchmark (`bench/P.hx`), its build script, the interleaved timer and a small IL disassembler are in
`.superpowers/research/hxc5-perf/` (local, git-ignored), with `NOTES.md`.

## What the person driving this decided

- **These three fixes**, nothing else in this round.
- **No observable change**: every program prints the same as today and as gencs, serialized data stays
  two-way compatible with today's gencs server, and every existing case passes.
- **All three apply with and without `-debug`.**
- **Out of scope:** IL tidying; `Std.int(intA / intB)` (hxc does a double divide, gencs an integer one,
  so `5/0` and `MIN/-1` differ: a parity question for another round); `Std.parseInt("-2147483648")`
  throwing `OverflowException` (an hxcs bug both builds share).
- **A method value stays exactly a `haxe.lang.Closure`** (`Type.getClass`/`getClassName`/`GetType()`
  unchanged): the fast path is an optional typed-invoker field on `Closure`, not a generated subclass
  (chosen over the subclass after the builder check found the class name would change).
- **When a method value throws**, what must stay the same is the exception type and message the caller
  catches, and the program's own Haxe frames in the same order. Reflection frames and hxc runtime frames
  (`callField`, `__hx_invokeDynamic`, `callMethodCasting`, …) may disappear from the trace.
- Picking the `HxObject` overload (section 3) was described to them and accepted.

Calls made by the writer of this document (check these):

- **Mistyped `Dynamic` calls behave as today.** The direct path runs only when each argument already has
  the parameter's type; otherwise the call goes by name as now (section 2).
- **`-D keep-inline-positions` keeps milestone 5's rule**: with it, stepping may visit hxc's runtime
  `Array.hx` inside an inlined `map`/`filter`. The debugger anti-goal holds without the flag.

## Goals

1. `a.map(f)` and `a.filter(f)` on hxc's runtime `Array<T>` are `inline`, as in Haxe 4.3.7's
   `std/cs/_std/Array.hx`, except on a receiver or a result whose type argument is `Dynamic`, a type parameter or still unbound at the call, which
   keeps today's call. With a function literal, the call becomes a loop with no closure allocated on the plain path and no
   boxing per element.
2. A method of a Haxe class used as a value (static, or an instance's) is still a `haxe.lang.Closure`,
   now carrying a generated typed invoker that calls the method directly. It behaves exactly as today's
   `Closure` does, apart from speed and the stack-trace frames named above.
3. Runtime's dynamic field calls (`getField`, `getField_f`, `setField`, `setField_f`, `callField`) use
   the overload C# would pick for the receiver's static type as gencs writes it: `HxObject` for a Haxe
   class that gencs makes an `HxObject` subclass, else `Dynamic`. A Float-typed result stays a `Float`
   (no `box Double` then `Runtime.toDouble`).

### Success

Measured with the interleaved timer on the benchmark (rebuilt with the new hxc):

- `array-map-filter` and `reflect-field` at or below 1.1× gencs.
- `method-ref` (a static method passed and called twice per iteration) at least 50× faster than today.
- No other benchmark more than 10% slower than today's hxc build.

## Non-goals

- Changing gencs-visible behaviour anywhere, including to "fix" something (see Out of scope).
- General C# overload resolution for Haxe `@:overload` methods: goal 3 is only about which
  `haxe.lang.Runtime` overload hxc's own dynamic-field lowering calls.
- Faster `Reflect.callMethod` / `Reflect.field(o, "method")` closures made at run time by the runtime:
  they stay by-name `Closure`s.
- Method values that are not a Haxe class's own method: a `String` method, a .NET extern method, an enum
  constructor, a method of an `Array<Dynamic>` reached dynamically, a `super.method` value. These keep
  today's path (`TexprCalls.hx`, the `pushClosure` cases other than the static and instance ones).
- Making lambdas faster: they already have their own classes (`ClosuresToClass`).

## Anti-goals (a failure even if it gets faster)

- Any change in a program's output, including exception messages, which exception type a caller catches,
  `Std.string`, `Type.getClass` and `Type.typeof` of a function, and serialized data, apart from the
  changes listed under "Accepted changes" below.
- Non-deterministic output: the DLL and PDB stay byte-identical across two compiles and across folders
  (tests/dotnet/run.sh checks both).
- New ILVerify findings, or code that only verifies because the JIT is lenient (for example, a call from
  inlined code in a user class to a member that IL access rules hide from it).
- The debugger stepping into hxc's runtime `Array.hx` when stepping over a `map` line (without
  `-D keep-inline-positions`), or showing the generated invoker classes' frames as user code.

### Accepted changes

These differ from today's output, and were accepted after the whole-branch review. Inlining `map` and
`filter` moves these shapes to what gencs prints:

| shape | today | now and gencs |
|---|---|---|
| `a.map(x -> { a = [7,8,9,10]; x; })` (`filter` likewise) | `[1,2,3]` | `[1,8,9]` |
| a local `f` reassigned by the callback while `map` runs | `[2,3,4]` | `[2,200,300]` |
| `var r:Array<String> = [1,2].map(y -> (y:Dynamic))` | throws | `[1,2]` |
| `[1.5].map(y -> (y:Dynamic))` to `Array<String>` | throws | `[1.5]` |
| `[1].map(y -> (y:Dynamic))` to `Array<UInt>` | throws | `[1]` |
| `[1.5, 2.5].map(y -> untyped y)` to `Array<Int>` | `[2,2]` | `[1,2]` |
| a non-literal `f` returning Dynamic, to `Array<Int>` | `[2,2]` | `[1,2]` |

- Under full DCE, a by-name `d.map` no longer finds the method, as in gencs (case `array-map-dce-full`).
- A method value's generated frames: frames that are not the program's own Haxe frames may leave
  `haxe.CallStack` / `Exception.details()` / `Exception.StackTrace` text when a method value throws, and new
  ones arrive, with or without an exception. A program reading its own stack in a static method used as a
  value sees `P.st P_st__Invoke.__hx_call1_f haxe.lang.Closure.__hx_invoke1_f P.call`, one of them under a
  class name that looks like the program's.
- A crash that now runs: a method value of a plain override of a `@:compilerGenerated` method, in a class with
  no method of its own, dies with a stack overflow by name (today and gencs) and direct calls the override. A
  read on a `@:skipReflection` base stays by name, and still overflows.
- A value type cast to Dynamic that goes on to another value type converts as a Dynamic does, also outside
  `map` (ruling R21): `var i:Int = (x : Dynamic)` of 1.5 was 1 and is 2, as in gencs. The same rule takes an
  Int through Dynamic to an `Int64` from a value to gencs's InvalidCastException.

Known differences from gencs or from today that stay (rulings R24 onward):

- `var r:Array<Bool> = [1,2].map(y -> untyped y)` stays a compile error where today and gencs throw
  InvalidCastException: `untyped y` has no cast for the rule above to see.
- An all-null array through an inlined body cast to Dynamic (`[nullString].filter(y -> (y : Dynamic))`,
  `[nullString].map((y:Dynamic) -> y)` to `Array<Int>`) throws NullReferenceException where today and gencs give a
  value.
- Bool, .NET enum and Single through Dynamic to `Null<Int64>`, and Bool and .NET enum to `Null<Single>`, go from a
  compile error to a value where gencs throws.
- A Float stored through Dynamic into `NativeArray<Null<Int>>` goes from 1 to 2 where gencs keeps 1.5; Bool, .NET enum
  and Single rows go from a compile error to a value where gencs keeps the original.
- `map` and `filter` on an array of a type parameter (`Array<T>`, `Array<Null<T>>`), as receiver or result, keep the
  closure call: no gain there, and today's output, including where gencs's inlined loop differs, such as a
  reassignment of the receiver by the callback.

## Constraints

- The test suite: `tests/dotnet/run.sh --compiler bin/cpp/windows/x64/release/bin/hxc.exe --std
  C:/HaxeToolkit/haxe/std` (607 cases at 7e5a1219; about 10 minutes; each case compiled twice,
  ILVerify'd, run, and for `@gencs` cases compared with gencs's run).
- Milestone 5's PDB rules: inlined code keeps the call site's position by default (Haxe's rule;
  `-D keep-inline-positions` keeps the inlined function's own), and generated code is hidden from the
  debugger and pinned out of `.hx` stack traces. New generated classes follow whatever M5 does for lambda
  closure classes.
- hxc's `Array<T>` forwards to a typed array once a cast made it one (`__hx_fwd`, the #8314 design in
  the main spec): every public method checks it first. The inlined methods keep that check.

## Design

### 1. Inline `Array.map` and `Array.filter`

In `src/hxc/codegen/dotnet/runtime/Array.hx` (`map` at about line 632, `filter` at about 660), mark both
`inline`, keeping today's results:

- A forwarding array (`__hx_fwd != null`) still gives `__hx_resolve().map(f)`'s result (and `cast` of
  `filter`'s). That branch must call a **non-inline** method (an inline method calling itself is an
  inlining loop). How it is split is the builder's call; Haxe's inliner needs a shape without an early
  `return` in a non-final position (an `if … else` expression works).
- `f` goes through Haxe's inliner, as in Haxe's std version. A function literal is substituted by the front
  end, as checked above. A local `f` (and a local receiver) is read each time round the loop, so the loop sees
  a reassignment by the callback while it runs; an `f` that is a call is evaluated once, before the loop.
- The inlined body runs in the caller's class. Every member it touches must be accessible there in IL,
  as ILVerify checks. Haxe-private members of `Array` that today are IL-private would fail; the builder
  checks how hxc writes them and picks members accordingly.

A receiver or result whose type argument is `Dynamic`, a type parameter, or still an unbound monomorph at the
call, is not inlined: `Inline.tryInline` returns null for a method with `@:inlineUnlessDynamic` when either's
type argument follows to `TDynamic`, a type parameter's `TInst` (`follow` looks through `Null<T>`) or an
unbound `TMono`, and the call stays what it is today.

`iterator()`, `keyValueIterator()`, `__unsafe_get` and `__unsafe_set` are also `inline` in Haxe's std
and not in hxc's. They are left alone: hxc already wins every array benchmark that uses them.

### 2. Direct closures for a Haxe class's methods

Today (`TexprCalls.hx`, about lines 249 and 308): a static method as a value is
`new Closure(typeof(C), "name", hash)`, an instance method `new Closure(obj, "name", hash)` with `obj`
evaluated at that point.

New, in two parts:

- **Runtime.** `haxe.lang.Closure` (`runtime/cs/internal/Function.hx`, about line 297) gets an optional
  field holding a typed invoker (a new `haxe.lang.ClosureInvoker`, see the plan). `Closure` overrides the
  typed entry points `__hx_invoke0_o`/`_f` … `__hx_invoke5_o`/`_f` (today inherited from `VarArgsBase`,
  which goes by name; a call with six or more arguments already goes to `__hx_invokeDynamic`): when the
  invoker is set and accepts the arguments, they call it directly; otherwise they do exactly what
  `VarArgsBase` does today. Closures
  made at run time (`Reflect.field(obj, "f")`, `Runtime.closure`) leave it null and are unchanged.
  `Closure` stays the exact class of every method value.
- **Generated invokers.** For each such method that the program uses as a value, hxc generates one
  invoker class (once per method, program-wide). The value is still `new Closure(obj, "name", hash)` with
  today's `obj`, `field` and `hash`, plus the invoker (a constructor overload or a field store; the
  builder's call). A static method's invoker can be a single shared instance; an instance method's holds
  the receiver (or reads it from the `Closure`; the builder's call). The invoker overrides the entry
  points for the method's arity with a direct call: `call` of the static method, or `callvirt` of the
  instance method on the receiver cast to its class, so an override in a subclass is still the one
  called.

**Arguments: the direct path only for arguments of the right type.** Today the by-name path converts
arguments by reflection (`callMethodCasting`, `IConvertible.ToType`): through a `Dynamic`, `d(2.7)` to an
`Int` parameter gives 3 (rounding), `"5"` gives 5, and an argument that does not fit throws "Invalid
calling parameters for method …". The lambda conversions (`ClosuresToClass.fromFloat`/`fromDynamic`)
truncate and cast instead. So the invoker takes the direct call only when every argument already has its
parameter's type: on the `_f` path, an `Int` parameter's double is integral and in range (and the object
slot is `Runtime.undefined`); on the `_o` path, the object is of the parameter's type (`isinst`; a null
goes by name). Otherwise it goes by name, exactly as today. Statically typed Haxe calls pass this test
except for a null argument. Results are converted back as `VarArgsBase` does today.

Because the value is still a `Closure` with today's fields, these stay as they are without extra work:

- equality: `Closure.Equals` compares `obj` and `field` through `Lib.as(obj, Closure)`, so
  `Reflect.compareMethods(P.inc, P.inc)`, `==` through `Runtime.eq`, and `GetHashCode` agree with
  by-name closures made at run time (`Reflect.field(obj, "f")`);
- `Type.getClass`, `Type.getClassName`, `GetType()`, `Type.typeof`, `Reflect.isFunction`, and
  `is Closure` / `Std.isOfType(f, haxe.lang.Closure)` in Haxe or inline C#;
- a new object on each read (no caching), as today and as the M4 rulings require;
- calls with the wrong number of arguments, `Reflect.callMethod` and every other path that reaches
  `__hx_invokeDynamic`: inherited, by name, unchanged.

Which methods get an invoker and which stay on today's path is the builder's call, under one rule: **a
shape goes direct only if every observable behaviour is the same** (apart from the frames named in
"What the person driving this decided"). Shapes to decide on explicitly, each
covered by a case either way: optional and rest arguments, six or more arguments, generic methods
(`function f<T>`), methods of generic classes, `@:overload` methods, `dynamic` methods (already a field,
not a `Closure`), methods whose class is `@:nativeGen`.

Behaviours that need a case each:

- **An exception thrown inside the method** (a Haxe exception and a native one, such as a null
  dereference). Today it goes through reflection, and the runtime rethrows `TargetInvocationException`'s
  `InnerException` (`Runtime.hx`, about line 502), which resets a native exception's stack. The bar: the
  caller catches the same exception type with the same message, and the program's own Haxe frames
  appear in the same order. Since gencs's frame list holds reflection frames, this case cannot take
  gencs's output as its expectation: it prints the type, the message and only the program's own frames
  (for example those whose class is the case's), with a hand-written `[run]` section. A small throwing
  method may be inlined by the JIT, as any direct call may be; the case's method must not be one the
  JIT inlines (for example one with a loop), or the case says why its frame is absent.
- **A `Dynamic` call with mistyped arguments** (`2.7` and `"5"` to an `Int` parameter, an argument that
  does not fit): the same result or error as today, `@gencs`.
- **`Std.string`, `Type.getClassName(Type.getClass(f))`, `Type.typeof(f)` of the method value**: same as
  today, `@gencs`.

Invoker class names are deterministic, cannot collide with user or lambda class names, and are emitted in
a deterministic order (the run.sh determinism check covers this). They are hidden from the debugger as
milestone 5 hides lambda closure classes.

### 3. The `HxObject` overloads of Runtime's field calls

In `TexprDynamic.hx` (`fieldGet` at about line 331, `fieldSet` at about 360, and the `callField`
equivalent), the Runtime overload is chosen today by `runtimeCall(name, LObject)`. Choose it as C#
would for the receiver as gencs types it: the `HxObject` overload when the receiver's static type is a
Haxe class that gencs makes a subclass of `haxe.lang.HxObject`, otherwise the `Dynamic` one. A receiver
typed as an interface, `Dynamic`, an anonymous structure, a type parameter or a `@:nativeGen` class keeps
the `Dynamic` overload unless the builder confirms C# picks `HxObject` for it.

This also changes what happens with a **null receiver**: the `HxObject` overload returns `0.0`/`null`
when `throwErrors` is false, and the `Dynamic` one goes through `slowGetField`. Since gencs calls the
`HxObject` overload, the new behaviour is gencs's; a `@gencs` case with a null receiver of a class type
shows it (and shows whether today's hxc differed from gencs).

When the access is typed like a Float and its value goes to a Float-like destination, the `getField_f`
result stays a `float64`, with no `box Double` / `Runtime.toDouble` round trip.

## Testing

- New `@gencs` cases in `tests/dotnet/cases.hx.txt` for each fix, including those named above (the
  forwarding array through `map`/`filter`, each method-value shape decided, a throwing method value,
  `Std.string` of a method value, `Reflect.compareMethods` mixing a direct closure with a run-time
  `Reflect.field` closure, a null class-typed receiver). Each must match gencs's output, except the
  throwing-method case, which has a hand-written expectation (section 2).
- The full suite passes, including the determinism, ILVerify and PDB checks.
- The milestone 5 debugger checklist (`tests/dotnet/debugger/`) gets a step for stepping over a `map`
  line and through a method value, run by hand by the person driving this.
- The benchmark numbers in Success, from the interleaved timer, go in the plan's final report. Timing is
  not added to CI (other processes on the machine skew it by up to 2×).

## Left to the builder

- How `map`/`filter` are split around the forwarding branch, and which members the inlined body uses.
- The invoker classes' names, base type, where they are emitted, whether `ClosuresToClass` builds them,
  and how the `Closure` receives its invoker.
- Which method shapes go direct, under the rule in section 2, with a case for each.
- How the overload choice in section 3 is expressed (a helper next to `runtimeMethod`, or a parameter).
- Whether to copy the benchmark into the repo (for example `tests/dotnet/bench/`) as a manual tool.
