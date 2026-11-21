# --dotnet on the .NET reference pack, phase 1: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `--dotnet` types Haxe code against the .NET SDK's reference pack, so .NET 10 APIs (System.Text.Json, HttpClient, Channels, newer collections) are callable, and what Haxe cannot express yet is left out and listed.

**Architecture:** `NetSetup` loads every DLL of `Microsoft.NETCore.App.Ref/<N>.0.x/ref/net<N>.0` as std when `--dotnet` is used without `--net-std`, and defines `dotnet_refpack`. Under that define, `NetConverter` leaves out members by fixed rules through one `leaveOut` helper, which records each one for `-D dotnet-netlib-report`, and makes C#-omittable parameters of non-virtual members optional. The typer marks the arguments it pads, so the IL generator's existing `pushDefault` fills them as C# would. Two converter/generator bugs found by the spike are fixed for both reference sets.

**Tech Stack:** Haxe 4.3.7 sources compiled by hxcpp (native hxc) and by hxc itself (.NET host); C# fixture libraries (`dotnet build`); bash test drivers.

**Spec:** `docs/superpowers/specs/2026-11-20-dotnet10-reference-pack-design.md`. Read it before any task. The spike branch `spike/dotnet10-refs` (worktree `.claude/worktrees/dotnet10-spike`, uncommitted changes) shows working first versions of Tasks 1, 3 and part of 4: read `git -C .claude/worktrees/dotnet10-spike diff`. Do not merge from it.

## Global Constraints

- Work in a worktree off `main` (the main checkout has other sessions' uncommitted changes). Stage only the files each task names. Never commit with the work email; the repo is set to the GitHub noreply address.
- Commit trailer on every commit: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Never write the private apps' names, their paths or the work email into the repo; say "the server app" and "the desktop app".
- `--cs` and `--cs -D dotnet` output must stay byte-identical for every existing case (goal 7). The only conversion change on the Mono path is Task 1's `ref`/`out` erasure fix, and Task 2's generic-base fix.
- The rules of Tasks 3–7 apply only when `dotnet_refpack` is defined (a `--dotnet` build without `--net-std`), to every assembly that build converts, including `--net-lib` DLLs.
- Default `-D dotnet-version` is 10 (`GenerateDotnet.defaultVersion`). A missing pack is a compile error that names the version and says to install the .NET SDK.
- Report line format, exactly: `left out <Type>.<member> <signature>: <reason>`, where `<Type>` is `NetConverter.ilpathS(cls.cpath)` and `<signature>` is `IlMetaTools.ilsigS(...)` of the member. The lines are sorted and deduplicated, and printed after the compile with `ctx.info` next to `-D dotnet-stub-report`'s lines. `-D dotnet-netlib-report` alone (value `1`) prints every line. `-D dotnet-netlib-report=<prefix>[,<prefix>...]` prints only the lines whose `<Type>` starts with one of the prefixes.
- A case's compile output, report lines included, is its `[compile]` section even when the build succeeds; `[run]` follows it. Report cases therefore always pass `=packlib`, so the framework's own left-out members stay out of expectations.
- Reason strings, exactly: `static abstract interface member`, `ref return`, `ref field`, `byref-like type <ilpathS>`, `function pointer`, `unmanaged pointer without -D unsafe`, `event named like a member`, `property already declared`.
- Exit criterion for speed: hello-world with `--dotnet` builds within 0.3 s of `--cs -D dotnet` (pinned to big cores, `ProcessorAffinity 0xFF`, best of 3).

**Build and test commands** (from the worktree root, Git Bash):
- Native hxc: `AEDIFEX_ROOT=D:/_github/hxc-toolchain/aedifex/ HAXE_STD_PATH=C:/HaxeToolkit/haxe/std haxelib run aedifex build cpp .`. Add `HXCPP_COMPILE_THREADS=4` if memory is short. Output: `bin/cpp/windows/x64/release/bin/hxc.exe`, called `$HXC` below.
- .NET suite: `tests/dotnet/run.sh --compiler $HXC --std C:/HaxeToolkit/haxe/std [--case '<pattern>']`.
- Conformance: `cd D:/_github/haxe-conformance && neko run.n run --compiler $HXC --std 'C:\HaxeToolkit\haxe\std' --cases <worktree>/tests/cases --expected <worktree>/tests/expected [--family cs-target]`. Two failures are already there and unrelated: `hl-output/multitype-maps-many-ways` and `hl-setup/unresolved-extern`. One run in five may fail a random case with `harness error: std@file_delete`; rerun.
- New fixture libraries go in `tests/dotnet/netlib/<Name>/` (`<Name>.csproj` and `<Name>.cs`, like ModLib), and their names go in `run.sh`'s comment list at line 52.

## Review Focus

- A `--net-lib` assembly built for netstandard2.0 (it references `netstandard.dll`) used with `--dotnet` must resolve through the pack's `netstandard.dll` facade and run. Test: Task 3, `dotnet-refpack-netstandard-lib`.
- A Haxe class that overrides a virtual .NET method with a defaulted parameter must compile with every parameter required, and the override must be what .NET calls. Test: Task 6, `dotnet-optional-virtual-override`.
- Types that implement generic-math interfaces must keep their ordinary static members, even though the interface's static abstract members are left out: `Int32.Parse`, `Math.Clamp`, `String.Join`. Test: Task 8, `dotnet-api-generic-math-types`.
- Enumerating a pack collection through its struct enumerator (`HashSet_1<Int>.GetEnumerator()`, `MoveNext`, `Current`) must work. Test: Task 8, `dotnet-api-collections`.
- Dynamic access to a pack object (`var o:Dynamic = hs; o.Count`) must reach the .NET member at run time. Test: Task 8, `dotnet-api-collections`.

---

### Task 1: Static methods erase class type parameters in `ref`/`out` arguments

**Files:**
- Create: `tests/dotnet/netlib/GenLib/GenLib.csproj` (netstandard2.0, `AssemblyName` GenLib, the same properties as ModLib's) and `tests/dotnet/netlib/GenLib/GenLib.cs`
- Modify: `src/hxc/codegen/dotnet/NetConverter.hx:405-409` (the `LManagedPointer` branch of `convertIlmethod`'s argument loop)
- Modify: `tests/dotnet/run.sh:52` (fixture name list)
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Produces: the GenLib fixture (namespace `genlib`), which Task 2 extends.

- [ ] **Step 1: Write GenLib with `public class Holder<T> { public static bool TryMake(out T v) { v = default(T); return true; } }`, and the case**

```
# A static method's ref/out argument of the class's type parameter: Haxe 4.3.7 (and hxc) left `T0` unbound.
--- netlib-static-out-of-class-param @netlib=GenLib
import genlib.Holder;
class P {
	static function main() {
		var v:Dynamic = 5;
		var ok = Holder.TryMake(v);
		Sys.println(ok + " " + v);
	}
}
===
[run]
true null
```

The erased `T` is `Dynamic` on the Haxe side, so the call binds `Holder<object>` and `v` receives `default(object)`. If hxc binds another instantiation, check it against gencs (add `@gencs`) before changing the expectation.

- [ ] **Step 2: Run `tests/dotnet/run.sh --compiler $HXC --std C:/HaxeToolkit/haxe/std --case 'netlib-static-out-*'`.** Expected: FAIL, and the compile output contains `Type not found : T0`.
- [ ] **Step 3: Apply `change` to the pointee in that branch: `convertSignature(ctx, p, change(s))`.**
- [ ] **Step 4: Rebuild, then run the case.** Expected: PASS. Then run the whole .NET suite. Expected: no new failures, and every existing case's bytes unchanged (the suite compares dumps).
- [ ] **Step 5: Commit** `.NET: static methods erase class type parameters in ref and out arguments too`.

### Task 2: Inherited members of a generic base instantiated with repeated or reordered arguments

**Files:**
- Modify: `tests/dotnet/netlib/GenLib/GenLib.cs`
- Modify: the code that computes the MemberRef parent of an inherited extern member. Not located yet; start from `TexprCalls.hx` `externCallSite`/`pushExternArgs` (~1300-1345), `g.types.classArgs`, and `ExternMembers.method`'s `parent`, which is built by `chainFrom` (`ExternMembers.hx:238`).
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: GenLib from Task 1.

- [ ] **Step 1: Add to GenLib** `public class Pair<A, B> { public A First; public B Second; public string Show() { return First + "/" + Second; } public A GetFirst() { return First; } }`, `public class Same<T> : Pair<T, T> {}`, `public class Swap<A, B> : Pair<B, A> {}`.
- [ ] **Step 2: Write the case** `netlib-generic-base-repeated-and-swapped-args @gencs @netlib=GenLib`. It does `var s = new Same<Int>(); s.First = 1; s.Second = 2;` and prints `s.Show()` and `s.GetFirst()`. Then `var w = new Swap<Int, String>(); w.First = "x"; w.Second = 5;` and prints `w.Show()` and `w.GetFirst()`. Expected `[run]`: `1/2`, `1`, `x/5`, `x`.
- [ ] **Step 3: Run it.** Expected: FAIL with `BadImageFormatException` when it runs, or an ILVerify report. Dump the call's MemberRef (`dotnet tests/fixtures/hxccheck/bin/out/HxcCheck.dll dump <dll> P`). It shows a parent such as `Pair`2<int32, !1>`.
- [ ] **Step 4: Fix where the parent is computed so the instantiation is substituted down the super chain** (use superpowers:systematic-debugging). The parent must be `Pair`2<int32, int32>` for `Same<Int>` and `Pair`2<string, int32>` for `Swap<Int, String>`.
- [ ] **Step 5: Run the case and the whole .NET suite.** Expected: PASS; existing bytes unchanged.
- [ ] **Step 6: Commit** `.NET: an inherited member of a generic base names the base as the subclass instantiates it`.

### Task 3: `--dotnet` reads the reference pack, with the leave-out helper and the report

**Files:**
- Modify: `src/hxc/Compiler.hx:807-814` (`--dotnet` case) and `:4580-4592` (the hxcs auto-add)
- Modify: `src/hxc/codegen/dotnet/NetSetup.hx` (`beforeGenerate`)
- Modify: `src/hxc/codegen/dotnet/NetConverter.hx` (new `leaveOut`; rules 1 and 2; the ArrayAccess loop at :651-659)
- Modify: `src/hxc/context/Context.hx` (new field)
- Modify: `src/hxc/codegen/dotnet/GenerateDotnet.hx:676-680` (print the report)
- Modify: `src/hxc/compiler/Usage.hx:99` (add `dotnet-netlib-report`)
- Modify: `src/hxc/codegen/dotnet/runtime/sys/io/File.hx` (qualify the `FileStream` enum arguments, as the spike did)
- Modify: `tools/dotnet-host/build.sh:89` (`--dotnet hxc` → `--cs hxc -D dotnet`)
- Modify: `.github/workflows/ci.yml:187-188` (the "Builds without hxcs" step: `--dotnet out` → `--cs out -D dotnet`. `--dotnet` no longer reads hxcs. That file has another session's uncommitted edits in the main checkout; edit only these two lines in the worktree.)
- Modify: `README.md` (the target table rows and the ".NET output" section: which references each flag uses; `--dotnet` needs the .NET SDK)
- Modify: `tools/stdall.sh` (optional third argument `--dotnet` builds with `--dotnet h` instead of `--cs h -D dotnet`)
- Create: `tests/dotnet/netlib/PackLib/PackLib.csproj` (net10.0, `AllowUnsafeBlocks` true) and `PackLib.cs`
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Produces:
  - define `dotnet_flag`: set by `--dotnet` only.
  - define `dotnet_refpack`: set by `NetSetup.beforeGenerate` when it loads the pack. Everything else tests this one.
  - `NetConverter.leaveOut(com:Context, what:String, why:String):Dynamic`. It records `"left out " + what + ": " + why` and throws `Exit`. `what` is `<Type>.<member> <signature>`.
  - `Context.netLeftOut:Map<String, Bool>`, written under `NetConverter.leftOutLock:sys.thread.Mutex` (conversion runs on several threads).
  - The PackLib fixture (namespace `packlib`), which Tasks 4–6 extend.

- [ ] **Step 1: Write PackLib.** Contents:
  - `public interface IShape { static abstract IShape Make(); int Sides(); }`
  - `public class Square : IShape { public static IShape Make() { return new Square(); } public int Sides() { return 4; } }`
  - `public class Store { int v = 3; public ref int Slot() { return ref v; } public int Plain() { return v; } }`
  - `public class RefIdx { int[] a = { 1, 2, 3 }; public ref int this[int i] { get { return ref a[i]; } } public int Get(int i) { return a[i]; } }`
- [ ] **Step 2: Write the cases** (all `@dotnet-flag`):
  - `dotnet-refpack-references`: `@dump=refs`, `Sys.println("hi")`. The expectation is what the build prints, once you have checked that no `assemblyref` line names `mscorlib` and one names `System.Runtime 10.0.0.0`.
  - `dotnet-flag-missing-pack`: `+ -D dotnet-version=99`. `[compile]` holds the error naming `.NET 99` and saying to install the .NET SDK.
  - `dotnet-refpack-left-out-report @netlib=PackLib + -D dotnet-netlib-report=packlib`: uses `new Square().Sides()`, `new Store().Plain()`, `new RefIdx().Get(1)`. `[compile]` holds exactly these report lines: `packlib.IShape.Make` (`static abstract interface member`), plus `packlib.Store.Slot` and `packlib.RefIdx.get_Item` (both `ref return`). `[run]` is `4`, `3`, `2`.
  - `netlib-report-rules-off-on-mono @netlib=PackLib + -D unsafe -D dotnet-netlib-report=packlib`: a plain (`--cs -D dotnet`) case using only `new Store().Plain()`. There is no `[compile]` section, because on Mono `Slot` still converts (to `cs.Pointer`, hence `-D unsafe`) and is not left out; `[run]` is `3`. This shows the Task 3 rules stay off the Mono path. (Mono cases use only `Store` and, from Task 6, `Opt` from PackLib: `IShape`'s static abstract member is not something the Mono path can convert.)
  - `dotnet-refpack-left-out-is-unknown @netlib=PackLib`: `new Store().Slot()` → `[compile]` with Haxe's unknown-field error for `Slot`.
  - `dotnet-refpack-netstandard-lib @netlib=ModLib`: `modreq-free-siblings`' program (from `netlib-modreq-free-siblings-work`) with `--dotnet` gives the same `[run]`.
  - Keep `netlib-modreq-members-are-refused` unchanged. It is the Mono-path guard.
- [ ] **Step 3: Run `--case 'dotnet-*'`.** Expected: the new cases FAIL (today `--dotnet` reads Mono references).
- [ ] **Step 4: Implement the selection.**
  - `--dotnet` defines `dotnet_flag` and is dropped from the hxcs auto-add condition.
  - In `beforeGenerate`, before the `net_ver` logic: when `dotnet_flag` is defined and `ctx.netStd.length == 0`:
    - define `net_ver=50`, `NET_20` … `NET_50`, `net_target=netcore`, `netcore` and `dotnet_refpack`;
    - `referencePack(ctx)` or throw `"--dotnet needs the .NET " + dotnetVersion(ctx) + " reference pack (Microsoft.NETCore.App.Ref): install the .NET SDK"`;
    - push every `.dll` of it, sorted ignoring case, into `ctx.netStdFiles`; load each; return.
  - Check that no std or runtime code reads `net_ver`, `netcore` or `net_target` in a way the new values break: `grep -rn "net_ver\|netcore\|net_target" std/ src/hxc/codegen/dotnet/runtime` and `C:/HaxeToolkit/haxe/std/cs`. Record what you find in the commit message.
- [ ] **Step 5: Implement `leaveOut` and rules 1 and 2, under `dotnet_refpack`.**
  - In `convertIlmethod`, leave out:
    - an interface's static method with `IAbstract` or `CMVirtual` (`static abstract interface member`);
    - a method whose `m.mret.snorm` is `LManagedPointer` (`ref return`).
  - In `convertIlprop`, leave out a property whose `psig.snorm` is `LMethod(_, LManagedPointer(_), _)` (`ref return`).
  - In `convertIlfield`, leave out a field whose `fsig.snorm` is `LManagedPointer` (`ref field`).
  - The ArrayAccess loop skips `LMethod(_, LManagedPointer(_), [_])`.
  - Turn the existing `hasUnmanaged` exits in the three converters into `leaveOut(..., "unmanaged pointer without -D unsafe")`.
  - Print `ctx.netLeftOut`'s sorted keys after generation when `dotnet_netlib_report` is defined, filtered by its value's prefixes unless the value is `1`.
  - The existing drops record their lines too, with or without `dotnet_refpack`:
    - in `normalizeIlcls`, an event removed because a method or property has its name: `left out <Type>.<event> <its type signature>: event named like a member`;
    - under `force_lib_check`, a property filtered as already declared: `property already declared`.
  - Go through every other `throw Exit` in `convertIlmethod`, `convertIlfield`, `convertIlprop` and `convertIlevent`. Each one stays silent only if it drops nothing callable: a non-public member, `.cctor`, `Finalize`, `Equals`/`GetHashCode` (inherited from `System.Object`), an `__hx_` name, or an accessor whose name lacks the `get_`/`set_` prefix. Note in a comment beside each why it is silent. Any other becomes a `leaveOut` with a new reason, which you add to Global Constraints in this plan and to the spec's list.
  - Usage entry: `{cat: ".NET (--dotnet, or --cs with -D dotnet)", name: "dotnet-netlib-report", doc: "Print the .NET library members left out because Haxe cannot call them yet, with the reason."}`.
- [ ] **Step 6: Qualify the `FileStream` arguments in the runtime `File.hx`; switch `build.sh`, the CI step, `stdall.sh` and the README.**
- [ ] **Step 7: Rebuild and run `--case 'dotnet-*'`, then the whole .NET suite.** Expected: all PASS; no existing case's bytes change.
- [ ] **Step 8: Run `tools/stdall.sh $HXC <tmp>/a` and `tools/stdall.sh $HXC <tmp>/b --dotnet`.** Expected: both `exit 0`, the same `stubbed` count, and the same stubbed lines.
- [ ] **Step 9: Build the .NET host with `tools/dotnet-host/build.sh $HXC <out dir outside the repo>`; compare its `hxc.dll` with one built from `main`.** Expected: identical (`cmp`).
- [ ] **Step 10: Commit** `.NET: --dotnet types against the .NET SDK's reference pack`.

### Task 4: Byref-like types and function pointers

**Files:**
- Modify: `src/hxc/codegen/dotnet/NetConverter.hx` (rule 3 in the three member converters; rule 4)
- Modify: `src/hxc/codegen/dotnet/NetLibrary.hx:259` (do not convert byref-like types; still visit their nested types)
- Modify: `tests/dotnet/netlib/PackLib/PackLib.cs`
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Produces:
  - `NetConverter.isByRefLike(ctx:NetLibCtx, path:IlPath):Bool`: `lookupIlclass` the type, then `hasAttr("IsByRefLikeAttribute", ["System", "Runtime", "CompilerServices"], cls)`. Cache by `ilpathS(path)` under `leftOutLock`.
  - `NetConverter.byRefLikeIn(ctx:NetLibCtx, s:IlSigNorm):Null<IlPath>`: the first byref-like value type anywhere in `s` (type arguments, array elements and pointees included), or null.
  - `NetConverter.hasFunctionPointer(s:IlSigNorm):Bool`.

- [ ] **Step 1: Add to PackLib:**
  - `public static class Spans { public static int Sum(ReadOnlySpan<int> s) { int t = 0; foreach (var x in s) t += x; return t; } public static int Sum(int[] a) { return Sum(new ReadOnlySpan<int>(a)); } public static Span<int> Make() { return new Span<int>(new int[2]); } }`
  - `public unsafe static class Fp { public static delegate*<int, int> Get() { return null; } public static int One() { return 1; } }`
- [ ] **Step 2: Write the cases** (`@dotnet-flag @netlib=PackLib`):
  - `dotnet-byref-like-left-out + -D dotnet-netlib-report=packlib`: `Spans.Sum(cs.Lib.nativeArray([1, 2, 3], false))` and `Fp.One()`. `[compile]` holds exactly: the `ReadOnlySpan` overload of `packlib.Spans.Sum` (`byref-like type System.ReadOnlySpan`1`), `packlib.Spans.Make` (`byref-like type System.Span`1`) and `packlib.Fp.Get` (`function pointer`). `[run]` is `6`, `1`.
  - `dotnet-byref-like-type-not-found`: `var s:cs.system.Span_1<Int> = null;` → `[compile]` holding Haxe's `Type not found : cs.system.Span_1`.
- [ ] **Step 3: Run them.** Expected: FAIL. Today `Span_1` exists and `Sum(ReadOnlySpan)` converts.
- [ ] **Step 4: Implement:**
  - rule 3 for parameters, returns, field types and property types (reason `byref-like type <ilpathS>`);
  - rule 4 (reason `function pointer`);
  - in `NetLibrary.build`, skip `convertIlClass` when `dotnet_refpack` is defined and the class is byref-like, but still visit `cls.cnested`.
- [ ] **Step 5: Run the two cases, all `dotnet-*` cases, and `stdall.sh --dotnet`.** Expected: PASS; the stubbed count is as in Task 3. In the commit message, record how many report lines rule 3 adds for the std build (`-D dotnet-netlib-report` added to a stdall run).
- [ ] **Step 6: Commit** `.NET: --dotnet leaves out byref-like types and function pointers`.

### Task 5: Extending or implementing a .NET type with a left-out abstract member is an error

**Files:**
- Modify: `src/hxc/codegen/dotnet/NetConverter.hx` (`convertIlClass` collects left-out abstract members into class metadata)
- Modify: `src/hxc/codegen/dotnet/GenerateDotnet.hx` (the check, before emission)
- Modify: `tests/dotnet/netlib/PackLib/PackLib.cs`
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: `leaveOut` (Task 3); rules 1–4.
- Produces:
  - class metadata `@:dotnetLeftOut("<member>", "<reason>")`, one entry per left-out member that is abstract: an instance abstract method of a class, any instance method of an interface, any static abstract or static virtual interface member.
  - `GenerateDotnet.checkLeftOutAbstracts(g:DotnetCtx):Void`. For each non-extern, non-abstract, non-interface Haxe class, it walks the super classes and the interfaces (recursively) for extern classes carrying the metadata. For each entry it reports: `dotnet: <Haxe class path> cannot be built: <extern class path>.<member> is abstract and was left out (<reason>)`, at the class position, as the other `dotnet:` diagnostics are reported.

- [ ] **Step 1: Add to PackLib** `public abstract class Reader { public abstract int Read(ReadOnlySpan<byte> b); public abstract int Count(); public int Twice() { return Count() * 2; } }`.
- [ ] **Step 2: Write the cases** (`@dotnet-flag @netlib=PackLib`):
  - `dotnet-left-out-abstract-refused`: `class R extends packlib.Reader { public function new() super(); override public function Count() return 1; }` → `[compile]` with the message for `packlib.Reader.Read` and `byref-like type System.ReadOnlySpan`1`.
  - `dotnet-left-out-static-abstract-refused`: `class S implements packlib.IShape { public function new() {} public function Sides() return 3; }` → `[compile]` with the message for `packlib.IShape.Make`.
  - `dotnet-left-out-abstract-subclass-allowed`: a Haxe `abstract class R2 extends packlib.Reader {}`, never instantiated and with no concrete subclass; `main` prints `new packlib.Square().Sides()` → compiles and runs, `[run]` `4`.
- [ ] **Step 3: Run them.** Expected: FAIL. The first two compile today and fail when they load.
- [ ] **Step 4: Implement the metadata and the check.**
- [ ] **Step 5: Run the three cases and all `dotnet-*` cases.** Expected: PASS.
- [ ] **Step 6: Commit** `.NET: a Haxe class cannot extend a .NET type whose abstract member was left out`.

### Task 6: Optional .NET parameters on non-virtual members

**Files:**
- Modify: `src/hxc/codegen/dotnet/ExternMembers.hx:1036` (make `canOmit` public), `:54-64` (`ExternCall` gains `?skipped:Array<Int>`), `applies` (~946: a position in `skipped` matches only when `canOmit(m.margs, i)`, and is not rated)
- Modify: `src/hxc/codegen/dotnet/NetConverter.hx` (`convertIlmethod` sets `opt: true`)
- Modify: `src/hxc/typing/Calls.hx:497-501` and `:565-567` (the two places that pad a null)
- Modify: `src/hxc/codegen/dotnet/TexprCalls.hx` (`externCallSite`, `pushExternArgs`)
- Modify: `tests/dotnet/netlib/PackLib/PackLib.cs`
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: `ExternMembers.canOmit(margs:Array<IlMethodArg>, i:Int):Bool`; `TexprCalls.pushDefault(arg, slot)`, which exists already.
- Produces:
  - `Calls.padOmitted(ctx:TyperContext, t:T, p:Position):TExpr`. It returns `TexprTools.makeNull(ctx.com.basic.tnull(t), p)`. When `dotnet_refpack` is defined, it wraps that null in `TMeta({name: ":dotnetOmitted", params: [], pos: p}, ...)`. Both padding sites call it; a `PosInfos` argument is still filled as today.
  - In the generator, for a .NET extern call:
    - trailing `:dotnetOmitted` arguments are removed before resolution, so the existing `omitted` path fills them;
    - a middle one is listed in `ExternCall.skipped` and gets `pushDefault(margs[i], slot)`;
    - a literal `TConst(TNull)` given for a value-type slot (not a `Nullable<T>` slot) also gets `pushDefault`.
  - For any other call, the IL generator treats `:dotnetOmitted` as the plain null inside it.

- [ ] **Step 1: Add to PackLib** `public class Opt` (public parameterless constructor) with:
  - `public static string Str(string s = "dflt") { return s ?? "null"; }`
  - `public static int Num(int a, int b = 7) { return a + b; }`
  - `public static string Mid(int a, string s = "m", int c = 3) { return a + s + c; }`
  - `public static string NulDef(double? x = 1.5) { return x.Value.ToString(System.Globalization.CultureInfo.InvariantCulture); }`
  - `public static string Dec(decimal d = 1.25m) { return d.ToString(System.Globalization.CultureInfo.InvariantCulture); }`
  - `public static int Params(int a, params int[] rest) { return rest.Length; }`
  - `public static string Optl([System.Runtime.InteropServices.Optional] object o) { return o == null ? "null" : o.GetType().Name; }`
  - `public static string Pick(int a) { return "one"; }` and `public static string Pick(int a, int b = 0) { return "two"; }`
  - `public virtual int V(int a, int b = 1) { return a + b; }`
- [ ] **Step 2: Write the cases** (`@dotnet-flag @netlib=PackLib`):
  - `dotnet-optional-defaults`: prints `Opt.Str()`, `Opt.Str(null)`, `Opt.Num(1)`, `Opt.Num(1, null)`, `Opt.Mid(1, 9)`, `Opt.NulDef()`, `Opt.Dec()`, `Opt.Params(1)`, `Opt.Optl()`, `Opt.Pick(1)` → `[run]` `dflt`, `null`, `8`, `8`, `1m9`, `1.5`, `1.25`, `0`, `Missing`, `one`.
  - `dotnet-optional-virtual-required`: `new Opt().V(1)` → `[compile]` holding `Not enough arguments`.
  - `dotnet-optional-virtual-override`: `class Sub extends packlib.Opt { public function new() super(); override public function V(a:Int, b:Int):Int return a * b; }`. Prints `new Sub().V(2, 3)` and `(new Sub() : packlib.Opt).V(2, 3)` → `[run]` `6`, `6`.
  - `dotnet-optional-json-serialize`: `cs.system.text.json.JsonSerializer.Serialize(d)` on a `Dictionary_2<String, Int>` holding a→1, b→2 → `[run]` `{"a":1,"b":2}`.
  - `netlib-optional-stays-required-on-mono @netlib=PackLib` (a plain `--cs -D dotnet` case): `packlib.Opt.Num(1)` → `[compile]` holding `Not enough arguments`.
- [ ] **Step 3: Run them.** Expected: FAIL. Today every parameter is required.
- [ ] **Step 4: Implement.**
  - Converter: `opt: true` for argument `i` when `dotnet_refpack` is defined, `ExternMembers.canOmit(m.margs, i)` holds, and the method is static, a constructor, or has no `CMVirtual` in its contract.
  - Typer: `padOmitted`.
  - Generator: trailing removal, `skipped`, literal null to a value type.
- [ ] **Step 5: Run the five cases, all `dotnet-*` and `netlib-*` cases, then the whole .NET suite and the conformance run.** Expected: PASS. Conformance is unchanged: the marker exists only under `dotnet_refpack`.
- [ ] **Step 6: Commit** `.NET: --dotnet makes C#-optional parameters of non-virtual members optional`.

### Task 7: Bare .NET enum values against .NET 10's larger overload sets

**Files:**
- Create: `tests/dotnet/netlib/OvlLib/OvlLib.csproj` (netstandard2.0) and `OvlLib.cs`
- Modify (one of): `src/hxc/typing/Calls.hx` or `src/hxc/typing/Overloads.hx` if hxc differs from Haxe. Otherwise nothing more: Task 3 already qualified `File.hx`.
- Test: `tests/dotnet/cases.hx.txt`

- [ ] **Step 1: Find out which `FileStream` constructors the .NET 10 pack declares and Mono's net-20 does not.** Use `-D net-loader-debug` on a one-line program that does `new cs.system.io.FileStream("p", cs.system.io.FileMode.Open)`, once with `--dotnet` and once with `--cs -D dotnet`, and diff the `method new` lines.
- [ ] **Step 2: Write OvlLib.** It holds its own enums `Mode { Open, Create }`, `Acc { Read, Write, ReadWrite }`, `Share { None, Read, ReadWrite }` and a class `Fs` whose constructors mirror the pack's `FileStream` list from Step 1, with `Mode`/`Acc`/`Share` in place of `FileMode`/`FileAccess`/`FileShare`. Each constructor sets `public string Which` to its own parameter list.
- [ ] **Step 3: Write the case** `netlib-bare-enum-values-many-overloads @gencs @netlib=OvlLib`: `new Fs("p", Open, Read, ReadWrite).Which`.
- [ ] **Step 4: Run it; compile the same program with Haxe 4.3.7** (`haxe -cp . -main P --cs out -D no-compilation --net-lib <OvlLib.dll>`).
  - If Haxe accepts it and hxc does not: fix hxc's typer to match (use superpowers:systematic-debugging). Then unqualify the runtime `File.hx` arguments and check that the `--dotnet` std still builds.
  - If both refuse it: change the case's expectation to that `[compile]` error and keep Task 3's qualification. Write the finding into the spec's "Spike evidence" section.
  - If the fixture does not reproduce the failure at all: write that into the spec too, keep the qualification, and drop the case.
- [ ] **Step 5: Run the case, all `dotnet-*` and `netlib-*` cases, and the conformance run.** Expected: PASS.
- [ ] **Step 6: Commit** `.NET: bare enum values against larger overload sets` (or `docs: ...` if only the spec changed).

### Task 8: The .NET 10 API checks

**Files:**
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: Tasks 2–6.

- [ ] **Step 1: Write the cases** (`@dotnet-flag`, each printing with `Sys.println`):
  - `dotnet-api-json`: `JsonSerializer.Serialize(d)` (a→1, b→2), and `JsonSerializer.Deserialize` of `{"a":3}` to `Dictionary_2<String, Int>`, printing `get_Item("a")`. Also `JsonDocument.Parse('{"x":[1,2,3],"y":"z"}')`, printing `GetProperty("y").GetString()` and `GetProperty("x").GetArrayLength()` → `{"a":1,"b":2}`, `3`, `z`, `3`.
  - `dotnet-api-channels`: `var ch:Channel_1<Int> = Channel.CreateUnbounded(); ch.Writer.TryWrite(41); var got = 0; ch.Reader.TryRead(got);` → `42` printed as `got + 1`.
  - `dotnet-api-collections`:
    - `PriorityQueue_2<String, Int>`: enqueue `low`/5 and `high`/1, then `Dequeue()` → `high`.
    - `HashSet_1<Int>`: `Add(3)`, `Contains(3)` → `true`; then enumerate it with `GetEnumerator()`/`MoveNext()`/`Current` → `3`; then `var o:Dynamic = hs; o.Count` → `1`.
    - `ConcurrentDictionary_2<String, Int>`: `TryAdd("k", 7)`, `get_Item("k")` → `7`.
  - `dotnet-api-http-client`: `var c = new HttpClient(); c.Timeout = TimeSpan.FromSeconds(5); c.Timeout.TotalSeconds` → `5`. No request is made.
  - `dotnet-api-generic-math-types`: `cs.system.Int32.Parse("42")`, `cs.system.Math.Clamp(15, 0, 10)`, `cs.system.Double.Parse("2.5", cs.system.globalization.CultureInfo.InvariantCulture)` → `42`, `10`, `2.5`.
- [ ] **Step 2: Run `--case 'dotnet-api-*'`.** Expected: PASS after Tasks 2–6. A failure here is a bug in one of them: fix it in the file that task owns, and add a case for it next to that task's cases.
- [ ] **Step 3: Note in the spec any call here where Haxe's overload pick differs from what C# picks.** Check `TimeSpan.FromSeconds(5)`: C# picks `FromSeconds(long)`. Record what hxc picks (`@dump=P` shows the MemberRef).
- [ ] **Step 4: Commit** `.NET: cases calling .NET 10 APIs through --dotnet`.

### Task 9: Whole-branch verification and the measured note

**Files:**
- Modify: `docs/superpowers/specs/2026-11-20-dotnet10-reference-pack-design.md` (a "Phase 1 measured" section in the "Spike evidence" style; the phase-2 list reordered by how often each category appears in the Task 8 report)

- [ ] **Step 1: Run the full .NET suite on the native hxc, then on the .NET host built from this branch** (`tools/dotnet-host/build.sh $HXC <out>`, then `--compiler <out>/hxc.exe`). Expected: all PASS on both.
- [ ] **Step 2: Run the conformance suite (all families) with both compilers.** Expected: only the two known failures.
- [ ] **Step 3: Run the .NET host bootstrap: build the host with `<out>/hxc.exe` into `<out2>`, then `cmp <out>/hxc.dll <out2>/hxc.dll`.** Expected: identical. Also identical to a host built from `main`.
- [ ] **Step 4: Run `stdall.sh` both ways.** Expected: exit 0 both times, with equal stubs.
- [ ] **Step 5: Time hello-world, `--dotnet` against `--cs -D dotnet`**, pinned (`ProcessorAffinity 0xFF`), best of 3. Expected: a difference of at most 0.3 s.
- [ ] **Step 5a: Check the report's categories.** Put Task 8's five programs together in one `main` in a scratch folder. Compile it with `--dotnet` and `-D dotnet-netlib-report`, then run `grep '^left out' | sed 's/.*: //' | sort | uniq -c`. Expected: only rules 1–4's reasons and the two existing-drop reasons. The counts go into the measured note.
- [ ] **Step 6: Write the measured note into the spec and commit** `docs: phase 1 measured`.
