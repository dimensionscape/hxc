# -D dotnet-seal: sealed leaf classes and final methods (short design)

2026-11-19. Third .NET speed round, kept from a throwaway spike.

## Why

Against Haxe 4.3.7's gencs + Roslyn, hxc's .NET output is level or faster on all but one of the 34
microbenchmarks in `.superpowers/research/hxc5-perf`, so a further gain has to come from something gencs
does not do. gencs, like hxc, makes every Haxe method `virtual` unless it is `final` or inline, and seals a
class only when Haxe marks it `final`. The JIT can call a virtual method directly, inline it, and test or
cast for a class with one method-table comparison only when it can prove the exact type. With dynamic PGO it
guesses and guards the guess; without PGO (ReadyToRun code, Native AOT, `TieredPGO=0`, the .NET-hosted hxc)
it does neither.

## What

`-D dotnet-seal`, off by default. With the whole program in one assembly, `TclassToIl.sealLeaves` (after
`openInheritedFinals`, before any TypeDef row):

- seals every class plan no other plan has as its base type;
- marks `final` each virtual method of an extended class when no plan below it has a method of that name
  overriding it (an overload of the same name counts as an override, which keeps it virtual: conservative).

Plans are followed by their base type (`superSig`), not the Haxe superclass, because an enum's constructor
classes have no `TClass` and override their enum class's methods. Interfaces, abstract classes, structs and
statics are left alone; MethodImpl rows only ever name interface methods, so no explicit override can point
at a method made final.

Off by default because it changes what other assemblies may do: they can no longer extend the sealed classes
or override the final methods (a library consumed from C#, mocking libraries, proxies).

## Approaches considered

1. **Seal leaves and finalize unoverridden methods, opt-in** (chosen): whole-program facts hxc already has,
   about 50 lines, no change to output without the flag.
2. **Jump tables (`switch`) for dense Int switches**: measured mixed. 16–32% faster when the hot case is late
   in the compare chain, 12–21% slower with an evenly spread or random selector, since one indirect jump
   mispredicts where a chain of well-predicted compares does not. Dropped.
3. **Seal by default**: gives the gain without asking, but changes behaviour for any assembly built to be
   extended. Not taken.

## Measured (pinned to the big cores, best of 5–7 runs)

| Benchmark | Plain | Sealed |
|---|---|---|
| Leaf-class virtual calls, TieredPGO off | 151 ms | 64 ms |
| Leaf-class virtual calls, PGO on | 55 ms | 48 ms |
| `is` / casts, PGO on | 40.0 ms | 35.6 ms |
| A game project's HashLink build through a sealed .NET-hosted hxc (median of 10) | 11.01 s | 10.90 s (noise) |

A game benchmark (parsing, decoding and simulated battles from a real Haxe game; 8 rounds, median of the
warm rounds over 3 interleaved runs, every checksum equal):

| Workload | Plain, default | Sealed, default | Plain, TieredPGO off | Sealed, TieredPGO off |
|---|---|---|---|---|
| boot | 219 ms | 206 ms | 154 ms | 156 ms |
| script parse | 31.9 ms | 30.5 ms | 61.1 ms | 53.7 ms |
| SVG parse | 130 ms | 123 ms | 82.5 ms | 83.6 ms |
| battles | 988 ms | 970 ms | 1407 ms | 1365 ms |
| AI only | 495 ms | 483 ms | 714 ms | 682 ms |
| whole run | 11.90 s | 11.38 s (-4.4%) | 13.70 s | 13.34 s (-2.6%) |

Blob decoding's median read 2.4x slower sealed with default settings, but round by round it is not: both
builds run about 110 ms (plain) or 85 ms (sealed) per round until the runtime swaps in its optimized code,
then 32–35 ms; the sealed build swaps one round later (round 5 instead of 4), which moved its median.

One benchmark (a 16-way enum switch in a loop, TieredPGO off) was 18% slower sealed. Its loop and callee
compile to identical machine code in both builds, the same methods are compiled in the same order at the same
tiers, and with `DOTNET_TieredCompilation=0` both take 89 ms. With `DOTNET_JitAlignLoops=0` the order flips
(sealed 80 ms, plain 88 ms). The cause is where the code lands in memory: sealed Tier0 code for earlier
methods is a few bytes smaller, which moves the hot loop. Not a property of sealing.

## Tests

`seal-leaf-classes` in `tests/dotnet/cases.hx.txt`: the type dump (sealed leaves, final unoverridden
methods, virtual overridden ones) and dispatch through a base class, an interface, a method value, `is`
checks and an enum. The whole .NET suite was also run with the flag added to every compile.
