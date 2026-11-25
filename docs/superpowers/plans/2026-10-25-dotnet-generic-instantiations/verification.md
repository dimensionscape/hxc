# Milestone 3c cases: verification

Cases assembled on 2026-10-25 from the three 3c research notes (`D:/_hxc3c/types`, `D:/_hxc3c/casts`,
`D:/_hxc3c/std`). Each one is checked against Haxe 4.3.7 gencs. hxc is
`bin/cpp/windows/x64/release/bin/hxc.exe` at main `bd47d661`, which was not rebuilt.

## How the cases were checked

- **@gencs cases (40 in the seven plan files, 4 in `m4.cases.txt`).** These ran through a copy of
  `tests/dotnet/run.sh` that reads a given case file. It has one extra mode that stops after `gencs_prepare`.
  `gencs_prepare` itself is unchanged: gencs with `-D no-compilation`, `gencs.csproj.in`, the batch MSBuild
  build (Release, `OutDir=bin/`) and `run_program`. The mode then compares gencs's normalized output with the
  case's `[run]`. For all 44 cases the output equals the `[run]` written here. Every program also ran three
  times (once, then `REPEAT=2`) and printed the same each time.
- **The same 44 cases with gencs's parent casts patched (decision 2).** Before the build, every parent-cast
  body in gencs's C# was rewritten by `fixcasts.py` (in this folder), which applies the types notes' §4 rule.
  That covers user classes and the std's `StringMap`, `IntMap`, `ObjectMap`, `BalancedTree` and
  `EnumValueMap`. All 44 outputs are still identical, so the fix changes none of them.
  - That run found one case the fix does change. In casts' `cast-interface`, the line `IMap from Dynamic` goes
    through `IMap__Statics_.__hx_cast` into `StringMap.haxe_IMap_cast`. Casts fact 5 calls this "a plain C#
    cast", but it isn't. With the patch the line prints 1, so it moved to `interface-cast-fixed`.
  - `fixcasts.py` gives exactly the researcher's hand patches for `thenable` and `supercast` (`g-fixed/src`).
- **Divergence cases.** These are not @gencs. Each one ran under unpatched gencs as well (with an `@gencs` tag
  added, no `[run]`), so its comment can quote gencs's output for contrast. Those quoted outputs match the notes.
  The exception is `companion-access-array-any`: there gencs's C# fails with CS0030, as types §5 says. The
  table below gives the source of each divergence case's expected `[run]`.
- **Today's hxc.** All 59 cases ran through the same harness copy with the `@gencs` tags stripped, so only hxc
  compiles, runs and is compared with the `[run]` written here. The last column summarizes that result: the
  compile refusals (and no .dll), an exception, or the number of differing `[run]` lines.

## Source changes made for determinism or for the decisions

- **`String.GetHashCode` is randomized per process on .NET.** This was checked with six runs of one program,
  each giving a different key order. So any StringMap with two keys or more iterates and serializes in a
  random order.
  - `cast-generic-copy` now sorts its two-key StringMap strings, and searches the original's serialization
    for `y1:qn`.
  - `cast-unserialize-typed` sets the map's existing key `a` instead of adding `c`.
  - `xml-attributes` prints toString and Printer for a one-attribute document.
- **Comparators `a < b ? -1 : 1` never return 0.** With them, hxcs's quicksort gives an order that depends on
  its input. `http-response-parsing` was caught flipping between repeated runs.
  - `http-response-parsing`, `xml-attributes` and `explicit-impl-erased-generic-interface` now use
    `a < b ? -1 : a > b ? 1 : 0`.
  - The researcher's QDyn method list in `explicit-impl-erased-generic-interface` was not sorted; the new
    gencs output is.
- **Other source edits.**
  - `DateTime.Now` became `DateTime.MinValue` in `type-argument-erasure` and `method-type-argument-erasure`;
    only the class is printed.
  - `Math.random() < 2` became a static flag in `cast-contexts`.
  - `thread-create` (m4) waits on a Lock for its second thread instead of sleeping.
- **Dropped or moved, with the decision behind each.**
  - The `mDyn` field was dropped from `erasure-edge-rules` (decision 7).
  - The Array `get_Item`/`set_Item` lists moved from `generic-reflection`, `resolve-generic-class` and
    `type-argument-clr-shapes` to `m4/array-companion-indexer` (decision 5).
  - The last cast of `typed-instantiation-casts`, an unhandled exception, was dropped.

## Per case

### erasure.cases.txt

| Case | Kind | gencs verified | Expected [run] from | Today's hxc (bd47d661) |
| --- | --- | --- | --- | --- |
| type-argument-erasure | @gencs | yes (also with patched parent casts) | the gencs run | runs; 62 diff lines vs expected |
| erasure-edge-rules | @gencs | yes (also with patched parent casts) | the gencs run | runs; 10 diff lines vs expected |
| native-generic-classes | @gencs | yes (also with patched parent casts) | the gencs run | runs; 10 diff lines vs expected |
| method-type-argument-erasure | @gencs | yes (also with patched parent casts) | the gencs run | runs; 18 diff lines vs expected |
| generic-instance-class-names | @gencs | yes (also with patched parent casts) | the gencs run | runs; 20 diff lines vs expected |
| all-enums-type | @gencs | yes (also with patched parent casts) | the gencs run | runs; 6 diff lines vs expected |
| null-binding-casts-ret | @gencs | yes (also with patched parent casts) | the gencs run | 3 compile errors, no .dll (first: "dotnet: a cast between instantiations of Array is not supported yet") |

### companions.cases.txt

| Case | Kind | gencs verified | Expected [run] from | Today's hxc (bd47d661) |
| --- | --- | --- | --- | --- |
| companion-members | @gencs | yes (also with patched parent casts) | the gencs run | runs; 28 diff lines vs expected |
| type-argument-clr-shapes | @gencs | yes (also with patched parent casts) | the gencs run | runs; 59 diff lines vs expected |
| cast-member-order | @gencs | yes (also with patched parent casts) | the gencs run | runs; 24 diff lines vs expected |
| interface-cast-fixed | divergence | no (not @gencs) | patched gencs: gencs C# of this program with every parent-cast body rewritten by fixcasts.py (types §4 rule), built and run as run.sh does | 3 compile errors, no .dll (first: "dotnet: a cast between instantiations of Th is not supported yet") |
| superclass-cast-fixed | divergence | no (not @gencs) | patched gencs (fixcasts.py, types §4 rule), built and run as run.sh does | runs; 12 diff lines vs expected; 6 lines with NotSupportedException |

### casts.cases.txt

| Case | Kind | gencs verified | Expected [run] from | Today's hxc (bd47d661) |
| --- | --- | --- | --- | --- |
| cast-map-member | @gencs | yes (also with patched parent casts) | the gencs run | 20 compile errors, no .dll (first: "dotnet: a cast between instantiations of haxe.ds.EnumValueMap is not supported yet") |
| cast-generic-copy | @gencs | yes (also with patched parent casts) | the gencs run | 2 compile errors, no .dll (first: "dotnet: a cast between instantiations of haxe.ds.StringMap is not supported yet") |
| typed-instantiation-casts | @gencs | yes (also with patched parent casts) | the gencs run | 5 compile errors, no .dll (first: "dotnet: a cast between instantiations of G is not supported yet") |
| cast-interface | @gencs | yes (also with patched parent casts) | the gencs run | 3 compile errors, no .dll (first: "dotnet: a cast between instantiations of Th is not supported yet") |
| cast-same-instantiation | @gencs | yes (also with patched parent casts) | the gencs run | 3 compile errors, no .dll (first: "dotnet: a cast between instantiations of Array is not supported yet") |
| cast-same-instantiation-8314 | divergence | no (not @gencs) | notes' stated hxc behaviour (casts §2.4-2.5 forwarding; decision 3) | 1 compile error, no .dll (first: "dotnet: a cast between instantiations of Array is not supported yet") |
| cast-contexts | @gencs | yes (also with patched parent casts) | the gencs run | runs; 28 diff lines vs expected; 14 lines with NotSupportedException |
| cast-contexts-working | divergence | no (not @gencs) | decision 4: the converted copy gencs gives `return cast d` for the same data ([2,2]) | runs; 4 diff lines vs expected; 1 line with NotSupportedException |
| generic-cast-matrix | @gencs | yes (also with patched parent casts) | the gencs run | 15 compile errors, no .dll (first: "dotnet: a cast between instantiations of Box is not supported yet") |
| generic-cast-matrix-8314 | divergence | no (not @gencs) | notes' stated hxc behaviour (casts §2.3-2.5 forwarding with the forwarder's length following the target; decision 3) | 1 compile error, no .dll (first: "dotnet: a cast between instantiations of Array is not supported yet") |
| null-binding-casts-fa | @gencs | yes (also with patched parent casts) | the gencs run | 2 compile errors, no .dll (first: "dotnet: a cast between instantiations of Array is not supported yet") |
| map-fields-in-classes | @gencs | yes (also with patched parent casts) | the gencs run | 8 compile errors, no .dll (first: "dotnet: a cast between instantiations of haxe.ds.StringMap is not supported yet") |

### companion-access.cases.txt

| Case | Kind | gencs verified | Expected [run] from | Today's hxc (bd47d661) |
| --- | --- | --- | --- | --- |
| companion-access | @gencs | yes (also with patched parent casts) | the gencs run | 6 compile errors, no .dll (first: "dotnet: a cast between instantiations of G is not supported yet") |
| companion-access-array-any | divergence | no (not @gencs) | decision 4 (gencs C# fails with CS0030); the callee reads length 3 | 1 compile error, no .dll (first: "dotnet: a cast between instantiations of Array is not supported yet") |
| cast-array-view | @gencs | yes (also with patched parent casts) | the gencs run | 9 compile errors, no .dll (first: "dotnet: a cast between instantiations of Array is not supported yet") |
| generic-enum-arguments | @gencs | yes (also with patched parent casts) | the gencs run | 4 compile errors, no .dll (first: "dotnet: enum arguments of generic class types are not supported yet") |

### reflection.cases.txt

| Case | Kind | gencs verified | Expected [run] from | Today's hxc (bd47d661) |
| --- | --- | --- | --- | --- |
| generic-reflection | @gencs | yes (also with patched parent casts) | the gencs run | 11 compile errors, no .dll (first: "dotnet: Std.isOfType with a generic type is not supported yet") |
| resolve-generic-class | @gencs | yes (also with patched parent casts) | the gencs run | runs; 65 diff lines vs expected |
| generic-is-of-type | @gencs | yes (also with patched parent casts) | the gencs run | 2 compile errors, no .dll (first: "dotnet: Std.isOfType with a generic type is not supported yet") |
| catch-generic-class | @gencs | yes (also with patched parent casts) | the gencs run | 1 compile error, no .dll (first: "dotnet: Std.isOfType with a generic type is not supported yet") |
| erased-interface-overload | @gencs | yes (also with patched parent casts) | the gencs run | runs; 4 diff lines vs expected |
| explicit-impl-erased-generic-interface | @gencs | yes (also with patched parent casts) | the gencs run | runs; 8 diff lines vs expected |
| serverapp-generic-tools | @gencs | yes (also with patched parent casts) | the gencs run | run matches the expected output (passes today) |
| list-lambda-generics | @gencs | yes (also with patched parent casts) | the gencs run | run matches the expected output (passes today) |

### array8314.cases.txt

| Case | Kind | gencs verified | Expected [run] from | Today's hxc (bd47d661) |
| --- | --- | --- | --- | --- |
| cast-array-convert | @gencs | yes (also with patched parent casts) | the gencs run | 4 compile errors, no .dll (first: "dotnet: a cast between instantiations of Array is not supported yet") |
| cast-array-lossless-serial | @gencs | yes (also with patched parent casts) | the gencs run | runs; 8 diff lines vs expected; ends with System.NotSupportedException: hxc dotnet: converting a value to Array<Int> is not supported yet |
| cast-8314-issue | divergence | no (not @gencs) | casts §6.11 stated hxc output | runs; 4 diff lines vs expected; 2 lines with NotSupportedException |
| cast-4872-eq | divergence | no (not @gencs) | casts §6.12 stated hxc output | 1 compile error, no .dll (first: "dotnet: a cast between instantiations of Array is not supported yet") |
| cast-array-dynamic-write | divergence | no (not @gencs) | casts §6.13 stated hxc output | runs; 7 diff lines vs expected; ends with System.NotSupportedException: hxc dotnet: converting a value to Array<Int> is not supported yet |
| cast-array-nested | divergence | no (not @gencs) | casts §6.14 stated hxc output | runs; 6 diff lines vs expected; ends with System.NotSupportedException: hxc dotnet: converting a value to Array<Array<Int>> is not supported y |
| nested-array-element-cast | divergence | no (not @gencs) | types §8.17 stated lines, plus `ai same: true` derived from casts §2.6 (Dynamic operand resolves the forward) | runs; 12 diff lines vs expected; ends with System.NotSupportedException: hxc dotnet: converting a value to Array<Array<Int>> is not supported y |
| cast-box-array-field | divergence | no (not @gencs) | casts §6.16 stated hxc output | runs; 5 diff lines vs expected; ends with System.NotSupportedException: hxc dotnet: converting a value to Box<Int> is not supported yet |
| array-dynamic-view-members | divergence | no (not @gencs) | decision 4: gencs's run with map/filter working ([2,4,6], [2,3]); other lines are gencs's | 3 compile errors, no .dll (first: "dotnet: a cast between instantiations of Array is not supported yet") |

### std.cases.txt

| Case | Kind | gencs verified | Expected [run] from | Today's hxc (bd47d661) |
| --- | --- | --- | --- | --- |
| timer-and-main-thread | @gencs | yes (also with patched parent casts) | the gencs run | runs; 14 diff lines vs expected; ends with System.NotSupportedException: hxc dotnet: sys.thread._Thread.HaxeThread.get uses a cast between inst |
| xml-attributes | @gencs | yes (also with patched parent casts) | the gencs run | runs; 24 diff lines vs expected; ends with System.NotSupportedException: hxc dotnet: Xml.exists uses a cast between instantiations of haxe.ds.S |
| http-response-parsing | @gencs | yes (also with patched parent casts) | the gencs run | 2 compile errors, no .dll (first: "dotnet: a cast between instantiations of haxe.ds.StringMap is not supported yet") |
| enum-value-map-arguments | @gencs | yes (also with patched parent casts) | the gencs run | runs; 12 diff lines vs expected; 6 lines with NotSupportedException |
| json-generic-values | @gencs | yes (also with patched parent casts) | the gencs run | runs; 17 diff lines vs expected; 4 lines with NotSupportedException |
| serialize-generic-values | @gencs | yes (also with patched parent casts) | the gencs run | runs; 69 diff lines vs expected; ends with System.NotSupportedException: hxc dotnet: converting a value to haxe.ds.ObjectMap<Dynamic, Dynamic>  |
| cast-unserialize-typed | @gencs | yes (also with patched parent casts) | the gencs run | 1 compile error, no .dll (first: "dotnet: a cast between instantiations of haxe.ds.StringMap is not supported yet") |
| generic-class-serial | @gencs | yes (also with patched parent casts) | the gencs run | runs; 12 diff lines vs expected; ends with System.NotSupportedException: hxc dotnet: converting a value to haxe.ds.StringMap<Dynamic> is not su |

### m4.cases.txt

| Case | Kind | gencs verified | Expected [run] from | Today's hxc (bd47d661) |
| --- | --- | --- | --- | --- |
| array-companion-indexer | @gencs | yes (also with patched parent casts) | the gencs run | runs; 19 diff lines vs expected; ends with System.NullReferenceException: Object reference not set to an instance of an object. |
| ereg-matched | @gencs | yes (also with patched parent casts) | the gencs run | runs; 14 diff lines vs expected; 7 lines with NotSupportedException |
| socket-timeout-select | @gencs | yes (also with patched parent casts) | the gencs run | runs; 7 diff lines vs expected; ends with System.NotSupportedException: hxc dotnet: sys.net.Socket.setTimeout uses the value of a .NET setter  |
| thread-create | @gencs | yes (also with patched parent casts) | the gencs run | runs; 13 diff lines vs expected; ends with System.NotSupportedException: hxc dotnet: sys.thread._Thread.HaxeThread.get uses a cast between inst |
| resource-strings | reference (not runnable) | no (not @gencs) | std researcher's probe.sh run with the resource embedded (run.sh cannot build it) | runs; 9 diff lines vs expected; ends with System.NullReferenceException: Object reference not set to an instance of an object. |
| cast-array-threads | divergence | no (not @gencs) | casts §6.15 stated hxc output (every round 7 of 7) | runs; 26 diff lines vs expected; ends with System.NotSupportedException: hxc dotnet: sys.thread._Thread.Thread_Impl_.create uses untyped code,  |
