# .NET runtime foundation (milestone 3a) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Haxe classes, `Dynamic`, reflection, anonymous objects and `Null<T>` behave under
`--cs <dir> -D dotnet` exactly as Haxe 4.3.7 gencs + hxcs make them behave, proven by a differential
suite that runs the same programs through gencs on .NET 10.

**Architecture:** hxc ships its own copy of the hxcs runtime (`cs/internal/*.hx`, inline C# rewritten
in Haxe and gencs's magic identifiers `__as__`/`__is__`/`__typeof__`/`__lock__`), embedded in the
binary by a build macro and served from a virtual class-path root, so the single-binary release
stays. Every Haxe class takes gencs's "hxgen" shape
(`haxe.lang.HxObject` base, split constructors, generated `__hx_*` reflection members keyed by
field hashes). `Dynamic` operations, anonymous objects and `Null<T>` lower to the same runtime calls
gencs emits. A `@gencs` flag in the test harness compiles each tagged case with Haxe 4.3.7 gencs,
builds the C# for `net10.0`, and requires identical output.

**Tech Stack:** Haxe 4.3 (hxc's source), hxcpp via Aedifex, the .NET 10 SDK, Haxe 4.3.7 + hxcs 4.2.0
(the oracle; already installed locally and on CI).

**Spec:** `docs/superpowers/specs/2026-10-21-dotnet10-il-generator-design.md`, milestone 3,
*"Runtime parity"*. Read *Compatibility*, *How it gets made* (Runtime) and *Casts between generic
instantiations* before starting.

**Milestone 3 is three plans.** This one (3a) builds the foundation. **3b** follows: closures and
local functions, enums, `Std`/`Type`/`Reflect` completeness, `haxe.Exception`, and the
`haxe.Serializer` corpus both ways. **3c** finishes the milestone: `__hx_cast` for generic Haxe
classes and the `Array` forwarding fix for Haxe issue 8314. Milestone 3's exit (the differential
suite passes, apart from recorded 8314 divergences) is checked at the end of 3c.

**Reference material** (GPL, read only, never copied into the repo): Haxe 4.3.7's
`src/generators/gencs.ml` and `src/codegen/gencommon/*.ml`, already downloaded with notes to
`C:/Users/JOEWIL~1/AppData/Local/Temp/claude/D---github-hxc/c9d8d778-a09f-433f-b6fc-7a14c96db3e0/scratchpad/ref/`
(`reflectionCFs.ml`, `overloadingConstructor.ml`, `objectDeclMap.ml`, `dynamicFieldAccess.ml`,
`dynamicOperators.ml`, `hardNullableSynf.ml`, `setHXGen.ml`, …). Real gencs output for probe
programs is in `D:/_hxcm3probe/out*/src` and `D:/_hxcm3probe2/*/out/src`, and the working gencs
build recipe in `D:/_hxcm3harness`. The runtime sources to copy are Haxe 4.3.7's
`std/cs/internal/*.hx` (MIT; keep their license header).

**Branch:** `git switch -c dotnet-il-m3a dotnet-il-generator`. Don't push or open a PR.

## Global Constraints

- Everything milestone 2's Global Constraints say still holds (`net10.0`, `--cs <dir> -D dotnet`,
  `-D dll-name`, byte-identical output, hxc writes PE/IL itself, ILVerify on every test assembly,
  no silent miscompiles, code style of `src/hxc/codegen/jvm/`, commit trailer
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`).
- Whatever stored data or the C# side can observe behaves like Haxe 4.3.7 gencs + hxcs; where hxcs
  has a bug data depends on, reproduce it (spec *Compatibility*). The oracle is gencs's C# built for
  `net10.0` with the harness's csproj, never hxcs's own `csc` build (it targets .NET Framework and
  formats doubles differently).
- hxc's runtime copy contains no `__cs__`, `cs.Syntax.code`, `@:functionCode` or `@:classCode`.
  Overriding runtime internals through the class path is not supported (spec *Runtime*).
- CLR names the C# side uses stay gencs's: `haxe.lang.HxObject`, `haxe.lang.IHxObject`,
  `haxe.lang.DynamicObject`, `haxe.lang.Runtime` and its public static members (`getField`,
  `setField`, `callField`, …), `haxe.lang.Null`1`, `haxe.lang.EmptyObject`, `haxe.lang.FieldLookup`.
- Field hashes are gencs's: at compile time, over the name's UTF-8 bytes, `h = h * 223 + byte`
  kept as a 31-bit value, then a negative value maps to `(h & 0x3FFFFFFF) | (1 << 30)`. At run
  time `FieldLookup.doHash` hashes UTF-16 code units the way hxcs does. The two differ for non-ASCII
  names, as in hxcs.

## Review Focus

1. **Non-ASCII field names**: gencs bakes the UTF-8 hash in, while `FieldLookup.hash` at run time
   hashes UTF-16, so reflection on such a field behaves as it does under hxcs, mismatch included.
   Test: `non-ascii-field-names` (`@gencs`) in Task 5.
2. **Two field names with the same hash** on one anonymous object or class: hxcs keeps both
   (`FieldHashConflict`, negative hashes in `DynamicObject`). Test: `hash-collision` (`@gencs`) in
   Task 7. Find a colliding ASCII pair with a short script and name it in the case.
3. **Concurrent `FieldLookup.hash` of new names** from many threads (server app issue 6551): no wrong
   name, no missed field, no exception. Test: `HxcCheck stress-fieldlookup` in Task 3.
4. **`Dynamic` arithmetic that turns an `Int` into a boxed `Double`** (`Runtime.plus` always
   returns a double; `d++` stores a double), then printed, compared or passed on. Test:
   `dynamic-operators` (`@gencs`) in Task 6.
5. **A missing field read through `Dynamic`**: on a class instance it throws
   `MemberAccessException("Field not found.")`, on an anonymous object it gives `null`, and
   `Reflect.field` gives `null` for both. Test: `missing-fields` (`@gencs`) in Task 6.

---

## File structure

| File | Responsibility |
| --- | --- |
| `src/hxc/codegen/dotnet/TexprToIl.hx` (split) | Core dispatch, `coerce`/`convert`, places |
| `src/hxc/codegen/dotnet/TexprOps.hx` | Numeric, comparison and string operators |
| `src/hxc/codegen/dotnet/TexprFlow.hx` | if/while/switch/return/throw/try and the try spill machinery |
| `src/hxc/codegen/dotnet/TexprCalls.hx` | Calls, constructors, receivers, member access, arrays |
| `src/hxc/codegen/dotnet/TexprDynamic.hx` | Runtime calls for `Dynamic`, anonymous objects, `Null<T>` |
| `src/hxc/codegen/dotnet/FieldHashes.hx` | Compile-time field hash; the set of hashed names |
| `src/hxc/codegen/dotnet/HxGen.hx` | hxgen decision, split constructors, the `__hx_*` reflection members |
| `src/hxc/codegen/dotnet/RuntimeSources.hx` | Build macro that embeds `runtime/**/*.hx`; the virtual root |
| `src/hxc/codegen/dotnet/runtime/cs/internal/*.hx` | hxc's copy of the hxcs runtime |
| `src/hxc/context/ModuleLoader.hx`, `Setup.hx`, `src/hxc/core/Position.hx` (modify) | Serve the virtual root |
| `tests/dotnet/run.sh`, `tests/dotnet/gencs.csproj.in` | The `@gencs` differential |
| `tests/fixtures/hxccheck/Program.cs` (modify) | `stress-fieldlookup` |

---

### Task 1: Split TexprToIl and test 4-byte metadata indices

Milestone 2's reviewers asked for both before milestone 3 grows the emitter.

**Files:**
- Create: `src/hxc/codegen/dotnet/{TexprOps,TexprFlow,TexprCalls}.hx`
- Modify: `src/hxc/codegen/dotnet/TexprToIl.hx`, `src/hxc/codegen/dotnet/GenerateDotnet.hx`
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Produces: `TexprToIl` keeps `texpr(ret, e)`, `coerce`, `convert`, `expr`, `block`, slots and
  places; `TexprOps`, `TexprFlow` and `TexprCalls` are classes constructed with the `TexprToIl`
  instance (`new TexprOps(t:TexprToIl)`) holding the code moved out of it; `TexprToIl` dispatches
  to them. Task 6 adds `TexprDynamic` the same way.

- [ ] **Step 1: Add the large-metadata case**

```
--- large-metadata-heaps
#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
class Gen {
	public static function build():Array<Field> {
		var fields = Context.getBuildFields();
		var sum = macro 0;
		for (i in 0...2500) {
			var name = 'field_with_a_rather_long_name_number_$i';
			fields.push({name: name, access: [APublic, AStatic], kind: FVar(macro :String, macro $v{name}), pos: Context.currentPos()});
			sum = macro $sum + $i{name}.length;
		}
		fields.push({name: "total", access: [APublic, AStatic], kind: FFun({args: [], ret: macro :Int, expr: macro return $sum}), pos: Context.currentPos()});
		return fields;
	}
}
#else
@:build(P.Gen.build())
class P {
	static function main() {
		Sys.println(total());
	}
}
#end
===
[run]
101390
```

2500 static field names (~100 KB) put `#Strings` past 64 KiB, so every `#Strings` index column
widens to 4 bytes; the 2500 initializer literals do the same for `#US`. Local variable names never
reach metadata, which is why the names are fields. The expected value is the sum of the literal
lengths: `2500 * 37 + 10 * 1 + 90 * 2 + 900 * 3 + 1500 * 4`. If hxc can't run a build macro defined
in the same file this way, generate the 2500 fields any other way that keeps them in one case.

- [ ] **Step 2: Run it**

Run: `tests/dotnet/run.sh --compiler bin/cpp/windows/x64/release/bin/hxc.exe --std C:/HaxeToolkit/haxe/std --case large-metadata-heaps`
Expected: `ok` (if it fails, fix the 4-byte index path in `MetaTables`/`MetaHeaps` in this task).

- [ ] **Step 3: Split `TexprToIl.hx` mechanically**

Move, without changing behavior: operators and strings (current lines ~540-1040) to `TexprOps`;
if/while/switch/return/throw/try and the spill machinery (~1041-1395) to `TexprFlow`; receivers,
member access, `Std.string`/String members, calls, constructors and arrays (~1395-2004) to
`TexprCalls`. Also clear `g.planOf` at the start of each left-out fixpoint round in
`GenerateDotnet` (a milestone 2 deferred finding).

- [ ] **Step 4: Run all cases**

Run: the build command (`AEDIFEX_ROOT=D:/_github/hxc-toolchain/aedifex/ HAXE_STD_PATH=C:/HaxeToolkit/haxe/std HXCPP_COMPILE_CACHE=D:/_github/hxc-toolchain/hxcpp-cache haxelib run aedifex build cpp .`), then `tests/dotnet/run.sh --compiler bin/cpp/windows/x64/release/bin/hxc.exe --std C:/HaxeToolkit/haxe/std`
Expected: all 63 cases `ok`, and every existing DLL byte-identical to before the split (compare
`a/P/*.dll` of a few cases before and after).

- [ ] **Step 5: Commit**

```bash
git add src/hxc/codegen/dotnet tests/dotnet/cases.hx.txt
git commit -m "Split the .NET expression lowering and test 4-byte metadata indices"
```

---

### Task 2: The `@gencs` differential

**Files:**
- Create: `tests/dotnet/gencs.csproj.in`
- Modify: `tests/dotnet/run.sh`, `tests/dotnet/cases.hx.txt`, `README.md` (the `.NET output` test paragraph)

**Interfaces:**
- Produces: the header flag `@gencs`. Every later task tags its runtime-behavior cases with it.

- [ ] **Step 1: Write the csproj template**

`tests/dotnet/gencs.csproj.in` is the SDK project from `D:/_hxcm3harness/hello/gc/P.csproj`:
`OutputType Exe`, `TargetFramework net10.0`, `AssemblyName` and `StartupObject` as placeholders
`@NAME@` / `@MAIN@`, `Nullable disable`, `ImplicitUsings disable`,
`EnableDefaultCompileItems false`, `Optimize true`, `DebugType none`,
`GenerateAssemblyInfo false`, `DefineConstants $(DefineConstants);NET_CORE`, `Compile Include="src/**/*.cs"`,
and `NoWarn` with `CS0108;CS0109;CS0114;CS0162;CS0164;CS0168;CS0169;CS0183;CS0184;CS0219;CS0252;CS0253;CS0414;CS0472;CS0618;CS0642;CS0649;CS0659;CS0660;CS0661;CS0665;CS0675;CS0693;CS0728;CS1717;CS1718;CS8981;SYSLIB0050`.

- [ ] **Step 2: Teach `run.sh` the flag**

`run.sh` gets `--haxe <path>` (default `haxe`). For each `@gencs` case, before the per-case loop
compares output:

1. **Generate** (can run in parallel across cases): in the case directory,
   `<haxe> --cwd <dir> --haxelib-global -cp . -main <module> --cs g -D no-compilation <extra>`; copy
   the template to `g/<module>.csproj` with `@NAME@` = the module's last segment and `@MAIN@` = the
   main class from `g/hxcs_build.txt` (between `begin main` and `end main`).
2. **Build all at once:** one generated MSBuild project in the tmp root, with a `Restore` task
   (`MSBuildRestoreSessionId` set to a fresh GUID) and a `Build` task
   (`Configuration=Release;OutDir=bin/`) over every `*/g/*.csproj`, both `BuildInParallel`;
   `dotnet build <batch>.proj -m -nologo -v q`.
3. **Run:** `dotnet g/bin/<name>.dll`, normalized like the hxc run.

The result gains a section `[gencs]` only when the gencs run's output differs from the hxc run's
`[run]` section; then the case fails. When a `@gencs` case's expected block has no `[run]` section,
the gencs output is the expectation for `[run]`. Without `@gencs`, nothing changes.

- [ ] **Step 3: Tag the milestone 2 cases that should already match**

Add `@gencs` to: `hello`, `println-boxes-values`, `static-calls-and-vars`, `extern-const`,
`extern-integer-constants`, `int-arithmetic`, `float-compare-nan`, `control-flow`, `switch`,
`strings`, `classes-and-inheritance`, `constructors-and-field-inits`, `static-init-order`,
`initializers-before-the-base-constructor`, `arrays`, `generic-classes-and-methods`,
`exceptions`, `std-string-keeps-casts`, `uint-mixed-with-int`, `net-equality-operators`,
`inventory`.

- [ ] **Step 4: Run them**

Run: `tests/dotnet/run.sh --compiler bin/cpp/windows/x64/release/bin/hxc.exe --std C:/HaxeToolkit/haxe/std`
Expected: all cases `ok`. A `[gencs]` difference is a real divergence: stop and report it with the
diff (do not untag the case or edit its expectation).

- [ ] **Step 5: Document and commit**

README: the tests also need Haxe 4.3.7 with hxcs on PATH for `@gencs` cases, and a case directory
path without spaces (hxcs fails on spaces; `HXC_TEST_TMP` sets it).

```bash
git add tests/dotnet README.md
git commit -m "Compare .NET test cases with Haxe 4.3.7 gencs built for net10.0"
```

---

### Task 3: hxc's embedded runtime and a thread-safe FieldLookup

**Files:**
- Create: `src/hxc/codegen/dotnet/RuntimeSources.hx`, `src/hxc/codegen/dotnet/runtime/cs/internal/{FieldLookup,HxObject,Runtime,Null,Function,StringExt}.hx`
- Modify: `src/hxc/context/ModuleLoader.hx` (`cacheDirectory`, `moduleFileContent`), `src/hxc/context/Setup.hx`, `src/hxc/Compiler.hx` (add the root with `-D dotnet`, next to the `jvm` overlay at ~line 1005), `src/hxc/codegen/dotnet/GenerateDotnet.hx` (`isStd`), `src/hxc/codegen/dotnet/TexprCalls.hx` (magic identifiers), `tests/fixtures/hxccheck/Program.cs`
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Produces:
  - `RuntimeSources.ROOT = "<hxc-dotnet-runtime>/"` and `RuntimeSources.get(path:String):Null<String>`
    (the embedded file for a path relative to the root, or null), built at hxc compile time by a
    macro reading `src/hxc/codegen/dotnet/runtime/**/*.hx`.
  - With `-D dotnet`, `ROOT` is the first class-path entry and counts as standard library for
    `isStd`. Positions in runtime files read `<hxc-dotnet-runtime>/cs/internal/Runtime.hx:…`.
  - gencs's magic identifiers in untyped code, lowered inline as gencs gives them meaning (the same
    ones hxcs's std uses, e.g. `cs.Lib.as` is `untyped __as__(obj)`): `__as__(e)` (`isinst` to the
    expression's type, `unbox.any` for a value type), `__is__(e, T)` (`isinst` + null test),
    `__typeof__(T)` (`ldtoken` + `System.Type.GetTypeFromHandle`), `__lock__(obj, body)`
    (`Monitor.Enter`/`Exit` in a try/finally).
  - hxc's `IHxObject` declares the `__hx_*` members of Task 5 as interface methods, so hxcs's
    `Reflect.hx` (`untyped ihx.__hx_getField(...)`) compiles unchanged.

- [ ] **Step 1: Write the failing case**

```
--- runtime-comes-from-hxc @dump=haxe.lang.FieldTable
class P {
	static function main() {}
}
===
[dump]
type public sealed beforefieldinit haxe.lang.FieldTable extends [mscorlib]System.Object
  field public int32[] ids
  field public string[] names
  method public hidebysig specialname rtspecialname void .ctor(int32[], string[])
```
(`haxe.lang.FieldTable` is the snapshot class of Step 3, `@:nativeGen final` with
`@:native("haxe.lang.FieldTable")`; it exists only in hxc's copy, so the dump proves the copy is
the one compiled. Writing the case may need a `try/finally` lowering for `__lock__`: add it in
`TexprFlow`.)

- [ ] **Step 2: Run them to see them fail**

Run: `tests/dotnet/run.sh --compiler bin/cpp/windows/x64/release/bin/hxc.exe --std C:/HaxeToolkit/haxe/std --case runtime-comes-from-hxc`
Expected: FAIL (FieldLookup today is Haxe's copy).

- [ ] **Step 3: Implement**

- Embed with a build macro (`@:build` or an expression macro returning a `Map` literal) that reads
  every `.hx` under `runtime/` relative to `RuntimeSources.hx`. It must work in both the Haxe build
  and hxc's self-host build (CI's "Build with hxc" step).
- Serve `ROOT` in `ModuleLoader.cacheDirectory` (list the embedded paths instead of the disk) and in
  `moduleFileContent` (return `RuntimeSources.get`), registering the content with
  `Position.registerFileContent` so diagnostics can quote it. The root never reaches `FileSystem`
  or `PathKey.fullPath`.
- The runtime copy starts as Haxe 4.3.7's `std/cs/internal/{FieldLookup,HxObject,Runtime,Null,Function,StringExt}.hx`,
  license header kept. Rewrite every inline-C# use in Haxe or with the magic identifiers above; the C#
  bodies in `Runtime`'s `@:classCode` (`getField`, `getField_f`, `setField`, `setField_f`,
  `callField`) become Haxe methods with the same signatures. The stub report after this task has no
  line naming `haxe.lang.FieldLookup` (other runtime classes still stub until Tasks 4-7).
- `FieldLookup` is thread-safe by design: the sorted ids and names live in one immutable snapshot
  object, read through a single `volatile` static reference (`System.Threading.Volatile.Read`);
  inserts copy the arrays under `lock(typeof(FieldLookup))` and publish the new snapshot with one
  `Volatile.Write`. `hash`, `lookupHash`, `findHash` and the conflict helpers keep their hxcs
  signatures and results.
- `HxcCheck stress-fieldlookup <dll>`: loads the assembly, and from 16 threads calls
  `haxe.lang.FieldLookup.hash` on 2,000 distinct new names each plus `lookupHash` on every result,
  checking every name maps back exactly; exits 1 on any mismatch or exception.

- [ ] **Step 4: Run all cases and the stress check**

Run: the build command, `tests/dotnet/run.sh …` (all cases), then compile `hello` to a scratch
directory and `dotnet tests/fixtures/hxccheck/bin/out/HxcCheck.dll stress-fieldlookup <dll>`.
Expected: all cases `ok`; the stress check exits 0. Then run it against a DLL built from Haxe's
own `FieldLookup.hx` (gencs's, via the harness) and record in the commit body whether it fails
there — the evidence that the change matters.

- [ ] **Step 5: Run hxc's own families** (the loader changed)

Run: `neko run.n run --compiler D:/_github/hxc/bin/cpp/windows/x64/release/bin/hxc.exe --std C:/HaxeToolkit/haxe/std --cases D:/_github/hxc/tests/cases --expected D:/_github/hxc/tests/expected -j 4` in `D:/_github/haxe-conformance`.
Expected: 110 checked, 0 failed.

- [ ] **Step 6: Commit**

```bash
git add src/hxc tests
git commit -m "Ship hxc's own hxcs runtime in the binary, with a lock-free-read FieldLookup"
```

---

### Task 4: The hxgen class model and split constructors

**Files:**
- Create: `src/hxc/codegen/dotnet/HxGen.hx`
- Modify: `src/hxc/codegen/dotnet/{TclassToIl,TexprCalls,GenerateDotnet,ModuleBuilder,MetaTables}.hx`
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Produces:
  - `HxGen.isHxGen(mt:ModuleType):Bool` — setHXGen.ml's rule: a non-extern class is hxgen unless
    `@:nativeGen`, `@:nativeChildren`, `@:struct` or below a `@:nativeChildren` class, but is hxgen
    anyway when its superclass or an interface is; an extern class only with `@:hxGen`; an enum
    unless extern or `@:nativeGen`.
  - `HxGen.ctorName(c:TClass):String` = `"__hx_ctor_" + c.pack.join("_") + "_" + c.name`
    (`__hx_ctor__Base` for a root class, `__hx_ctor_pk_sub_Thing` for `pk.sub.Thing`).
  - `ModuleBuilder.constant(parent:Int, c:IlConstant)` (a Constant table row, sorted by parent).

- [ ] **Step 1: Write the failing cases**

```
--- hxgen-shape @lib @module=pk.Thing @dump=pk.Base,pk.Thing,pk.NG
package pk;
class Base {
	public var a:Int;
	public function new(a:Int) {
		this.a = a;
	}
}
class Thing extends Base {
	var p = 0;
	public function new(a:Int, s:String) {
		super(a + 1);
	}
}
@:nativeGen class NG {
	public var q:Int;
	public function new() {}
}
===
[dump]
type public beforefieldinit pk.Base extends haxe.lang.HxObject
  field public int32 a
  method public hidebysig specialname rtspecialname void .ctor(haxe.lang.EmptyObject)
  method public hidebysig specialname rtspecialname void .ctor(int32)
  method family static hidebysig void __hx_ctor_pk_Base(pk.Base, int32)
type public beforefieldinit pk.Thing extends pk.Base
  field public int32 p
  method public hidebysig specialname rtspecialname void .ctor(haxe.lang.EmptyObject)
  method public hidebysig specialname rtspecialname void .ctor(int32, string)
  method family static hidebysig void __hx_ctor_pk_Thing(pk.Thing, int32, string)
type public beforefieldinit pk.NG extends [mscorlib]System.Object
  field public int32 q
  method public hidebysig specialname rtspecialname void .ctor()
```
(Task 5 adds the `__hx_*` reflection members; this case's expectation grows then.)

```
--- split-constructors @gencs
class Base {
	public var log:Array<String> = [];
	public function new(n:Int) {
		log.push("base " + n);
	}
}
class Mid extends Base {
	var tag = "m";
}
class Leaf extends Mid {
	public function new() {
		log.push("leaf before");
		super(7);
		log.push("leaf after " + tag);
	}
}
class P {
	static function main() {
		var l = new Leaf();
		Sys.println(l.log.join(","));
		var e:Leaf = Type.createEmptyInstance(Leaf);
		Sys.println(e.log == null);
	}
}
===
```

- [ ] **Step 2: Run them to see them fail**

Run: `tests/dotnet/run.sh --compiler bin/cpp/windows/x64/release/bin/hxc.exe --std C:/HaxeToolkit/haxe/std --case hxgen-shape`
Expected: FAIL.

- [ ] **Step 3: Implement**

As overloadingConstructor.ml and reflectionCFs.ml's `UniversalBaseClass` produce it (see the
probe output in `D:/_hxcm3probe/out/src`):

- An hxgen class without a superclass extends `haxe.lang.HxObject`; an hxgen class whose superclass
  isn't hxgen (e.g. `haxe.Exception : System.Exception`) implements `haxe.lang.IHxObject`; an hxgen
  interface extends `IHxObject`. `@:nativeGen` classes keep milestone 2's shape.
- Every hxgen class gets `public .ctor(haxe.lang.EmptyObject)`; the root's has no base call, the
  others call `base(EmptyObject.EMPTY)`. The real constructor calls `base(EmptyObject.EMPTY)`,
  then `ctorName(c)(this, args…)`. The static constructor is `family static` (`private` when the
  class is final) with `__hx_this` in place of `this`; its body is the instance var initializers
  (milestone 2's init_funcs order), then the constructor body, where `super(args)` becomes a call
  of the nearest ancestor's static constructor. A class without a constructor gets cloned
  constructors that call `super(...)`, or an empty `new()` when no ancestor has one.
- A class that descends from a native type keeps milestone 2's direct constructor chain (no static
  constructor), and its `EmptyObject` constructor calls the native base constructor with the fewest
  parameters, passing nulls (`haxe.Exception(EmptyObject) : base(null, null)`).
- `haxe.lang.EmptyObject` is `@:nativeGen enum EmptyObject { EMPTY; }` in the runtime: a
  `@:nativeGen` flat enum becomes a CLR enum (`sealed`, extends `[mscorlib]System.Enum`, an
  instance field `public specialname rtspecialname int32 value__`, and a `public static literal`
  field per constructor with a Constant row 0, 1, …); a switch on it compares the int values.
- `Type.createEmptyInstance(C)` with a constant hxgen class `C` is `newobj C::.ctor(EmptyObject)`
  with `ldc.i4.0` (overloadingConstructor's `init_expr_filter`).
- Member order: fields as before, then `.ctor(EmptyObject)`, the real constructor(s), instance
  methods, the static constructor, other statics, `Main()`, `.cctor`.
- Update the dumps of milestone 2 cases that now show `extends haxe.lang.HxObject` and the new
  constructors (`entry-point-in-main-class`, `entry-point-class-for-main`, `clr-names`,
  `extends-native-exception`, `generic-names`, `type-mapping`, …): only those lines change.

- [ ] **Step 4: Run all cases**

Run: the build command, then `tests/dotnet/run.sh …`
Expected: all `ok`, the `split-constructors` hxc output equal to gencs's.

- [ ] **Step 5: Commit**

```bash
git add src/hxc/codegen/dotnet tests/dotnet/cases.hx.txt
git commit -m "Give Haxe classes gencs's HxObject base and split constructors"
```

---

### Task 5: Field hashes and the `__hx_*` reflection members

**Files:**
- Create: `src/hxc/codegen/dotnet/FieldHashes.hx`
- Modify: `src/hxc/codegen/dotnet/{HxGen,TclassToIl,GenerateDotnet}.hx`, the runtime's `FieldLookup.hx`
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Produces:
  - `FieldHashes.hash(name:String):Int` (the compile-time hash from Global Constraints; `"a"` = 97,
    `"fl"` = 22854, `"dyn"` = 4999993, `"x_y"` = 5988786) and `FieldHashes.use(name):Int`, which also
    records the name for the `FieldLookup` table.
  - The emitted `FieldLookup` snapshot starts with every recorded name, sorted by hash.

- [ ] **Step 1: Write the failing cases**

Extend `hxgen-shape`'s expected dump: `pk.Base` and `pk.Thing` each gain these lines right after
their real constructor (each class reflects its own field: `a`, `p`; `virtual` without `newslot`,
since `HxObject` declares them):

```
  method public virtual hidebysig object __hx_getField(string, int32, bool, bool, bool)
  method public virtual hidebysig float64 __hx_getField_f(string, int32, bool, bool)
  method public virtual hidebysig object __hx_setField(string, int32, object, bool)
  method public virtual hidebysig float64 __hx_setField_f(string, int32, float64, bool)
  method public virtual hidebysig void __hx_getFields(Array`1<string>)
```
(Neither has methods of its own, so no `__hx_invokeField`.)

```
--- reflection-on-classes @gencs
class Base {
	public var a:Int = 1;
	public var f:Float = 2.5;
	public var s:String = "x";
	public var prop(get, set):Int;
	var hidden:Int = 3;
	public function new() {}
	function get_prop() return a * 10;
	function set_prop(v:Int) return a = v;
	public function twice(n:Int):Int return n * 2;
}
class Sub extends Base {
	public var extra:Array<Int> = [1];
	public function new() {
		super();
	}
	override public function twice(n:Int):Int return n * 3;
}
class P {
	static function main() {
		var o = new Sub();
		Sys.println(Reflect.fields(o).join(","));
		Sys.println(Reflect.field(o, "a"));
		Reflect.setField(o, "a", 5);
		Sys.println(o.a);
		Sys.println(Reflect.field(o, "f"));
		Sys.println(Reflect.getProperty(o, "prop"));
		Reflect.setProperty(o, "prop", 9);
		Sys.println(o.a);
		Sys.println(Reflect.hasField(o, "s") + " " + Reflect.hasField(o, "nope"));
		Sys.println(Reflect.isFunction(Reflect.field(o, "twice")));
		Sys.println(Reflect.field(o, "nope"));
	}
}
===
--- non-ascii-field-names @gencs
class P {
	static function main() {
		var o = new Holder();
		Sys.println(Reflect.field(o, "café"));
		Sys.println(Reflect.fields(o).join(","));
	}
}
class Holder {
	public var café:Int = 4;
	public function new() {}
}
===
```

- [ ] **Step 2: Run them to see them fail**

Run: `tests/dotnet/run.sh … --case reflection-on-classes`
Expected: FAIL (`Reflect.field` reaches stubbed runtime code today).

- [ ] **Step 3: Implement** the members exactly as reflectionCFs.ml generates them

- Signatures as in Step 1, plus on a root (`HxObject` itself, or an hxgen class extending a native
  type): `__hx_lookupField(string, int32, bool, bool)`, `__hx_lookupField_f(string, int32, bool)`,
  `__hx_lookupSetField(string, int32, object)`, `__hx_lookupSetField_f(string, int32, float64)`,
  and on `HxObject` only `bool __hx_deleteField(string, int32)` (returns false). Their bodies:
  `__hx_lookupField` returns `Runtime.undefined` when `isCheck`, throws
  `MemberAccessException("Field not found.")` when `throwErrors`, else null;
  `__hx_lookupField_f` throws `"Field not found or incompatible field type."` or returns 0.0;
  `__hx_lookupSetField` throws `"Cannot access field for writing."`; `__hx_lookupSetField_f` throws
  `"Cannot access field for writing or incompatible type."`.
- Each method is `switch (hash) { case <hash>: …; default: return base.<same>(args); }` (the root's
  default calls `__hx_lookup*`), emitted only when the class has a case. Fields covered: the
  class's own ordered fields minus `@:compilerGenerated` and `@:skipReflection`, `@:readOnly` out of
  both get and set; cases in reverse declaration order.
- `__hx_getField` cases: vars and dynamic methods return the value (boxed); normal methods return
  `new haxe.lang.Closure(this, "<name>", <hash>)`. `__hx_getField_f`/`__hx_setField_f` cases: only
  vars and dynamic methods whose type is like-float (Int, Float, UInt, not Int64), Dynamic or a type
  parameter (`(double)this.a`; `this.a = (int)value; return value;`; `Runtime.toDouble` /
  `Runtime.genericCast` for type parameters). `__hx_setField` cases convert with
  `Runtime.toInt`/`toDouble`/`toString`/a cast, store, and return the value.
- Properties: a non-physical `get`/`set` property's get case is `return get_prop();` and set case
  `set_prop(...); return value;`; a physical property (`@:isVar` with an accessor) uses the accessor
  only when `handleProperties`.
- `__hx_invokeField` cases: a non-override method converts `dynargs[i]` (`Runtime.toInt` etc.;
  optional arguments read `dynargs.Length > i ? dynargs[i] : null`) and calls it; an override
  method's case is `return Runtime.slowCallField(this, field, dynargs);`; the root's default is
  `((Function)__hx_getField(field, hash, true, false, false)).__hx_invokeDynamic(dynargs)`.
- `__hx_getFields(baseArr)`: `baseArr.push(name)` for each non-override var and dynamic method of
  the class (non-physical properties included), reverse declaration order, then
  `base.__hx_getFields(baseArr)`.
- `FieldLookup`'s initial snapshot holds every hashed name, sorted by hash (gencs.ml:3458-3507);
  hxc emits it as the snapshot field's initializer.
- `haxe.lang.Function`, `VarArgsBase` and `Closure` get the members closuresToClass gives them, so
  a method read as a value (a `Closure`) works: `Function` has `public int __fn_type`,
  `public int __hx_arity`, `.ctor(int32 arity, int32 type)`, `virtual object __hx_invokeDynamic(object[])`
  (switch on the count 0-6 calling `__hx_invokeN_o(0.0, args[0], …)`, else
  `ArgumentException("Too many arguments")`), and for N = 0..6 `virtual object __hx_invokeN_o(...)`
  and `virtual float64 __hx_invokeN_f(...)` with N `(float64, object)` parameter pairs (each throws
  `ArgumentException("Wrong number of arguments")` unless `__fn_type` is 1 or 0 respectively, else
  converts the other's result); `VarArgsBase` (`base(-1, -1)`) overrides every `__hx_invokeN_o/_f`
  to pack its arguments into `object[]` (the boxed double when the object part is
  `Runtime.undefined`) and call `__hx_invokeDynamic`. Lowering local functions into `Function`
  subclasses is plan 3b.

- [ ] **Step 4: Run all cases**

Run: the build command, then `tests/dotnet/run.sh …`
Expected: all `ok`.

- [ ] **Step 5: Commit**

```bash
git add src/hxc/codegen/dotnet tests/dotnet/cases.hx.txt
git commit -m "Generate gencs's __hx_* reflection members keyed by field hashes"
```

---

### Task 6: `Dynamic` field access, operators and conversions

**Files:**
- Create: `src/hxc/codegen/dotnet/TexprDynamic.hx`
- Modify: `src/hxc/codegen/dotnet/{TexprToIl,TexprOps,TexprCalls}.hx`, the runtime's `Runtime.hx`
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: `FieldHashes.use`, the runtime `Runtime` class.
- Produces: `TexprDynamic` with `fieldGet(obj:TExpr, name:String, resultSig:IlSigNorm, throwErrors:Bool)`,
  `fieldSet(...)`, `fieldCall(...)`, `operator(op, e1, e2, resultSig)`, `toSig(from, to)` for every
  Dynamic conversion. Milestone 2's refusals "Dynamic to Bool/Int/Float conversions", "Dynamic in
  string concatenation", "Dynamic as a condition", "Dynamic field access", "the … operator on these
  types" for Dynamic operands, and "checked casts" to classes go away.

- [ ] **Step 1: Write the failing cases**

```
--- dynamic-operators @gencs
class P {
	static var d:Dynamic = 2;
	static var e:Dynamic = 2.5;
	static var s:Dynamic = "4";
	static var n:Dynamic = null;
	static function main() {
		Sys.println(d + 1);
		Sys.println(d + e);
		Sys.println(d + s);
		Sys.println(d * 3);
		Sys.println(d / 4);
		Sys.println(d % 2);
		Sys.println(-d);
		var c:Dynamic = 1;
		c++;
		Sys.println(c);
		Sys.println(Std.isOfType(c, Int) + " " + Std.isOfType(c, Float));
		Sys.println(d == 2 && d != e);
		Sys.println(d < e);
		Sys.println(s < "5");
		Sys.println(n == null);
		var i:Int = e;
		Sys.println(i);
		var j:Int = cast 3.5;
		Sys.println(j);
		var b:Bool = n;
		Sys.println(b);
		Sys.println("v=" + d + e + n);
		if (n) Sys.println("never");
	}
}
===
--- dynamic-fields @gencs
class Point {
	public var x:Int;
	public var y:Float;
	public function new(x:Int, y:Float) {
		this.x = x;
		this.y = y;
	}
	public function sum(k:Int):Float return (x + y) * k;
}
class Point3 extends Point {
	override public function sum(k:Int):Float return super.sum(k) + 100;
}
class P {
	static function main() {
		var p:Dynamic = new Point(1, 2.5);
		Sys.println(p.x);
		p.x = 7;
		Sys.println(p.x + p.y);
		Sys.println(p.sum(2));
		Sys.println(Reflect.callMethod(p, Reflect.field(p, "sum"), [3]));
		var q:Dynamic = new Point3(1, 1);
		Sys.println(q.sum(1));
		Sys.println(Reflect.callMethod(q, Reflect.field(q, "sum"), [1]));
		var t:Dynamic = cs.system.Environment.NewLine.length > 0 ? "abc" : null;
		Sys.println(t.length);
	}
}
===
--- missing-fields @gencs
class C {
	public var a = 1;
	public function new() {}
}
class P {
	static function main() {
		var c:Dynamic = new C();
		Sys.println(Reflect.field(c, "b"));
		try {
			Sys.println(c.b);
		} catch (e:cs.system.MemberAccessException) {
			Sys.println("caught: " + e.Message);
		}
		try {
			c.b = 2;
		} catch (e:cs.system.MemberAccessException) {
			Sys.println("caught: " + e.Message);
		}
	}
}
===
```

- [ ] **Step 2: Run them to see them fail**

Run: `tests/dotnet/run.sh … --case dynamic-operators`
Expected: FAIL with "not supported yet" diagnostics.

- [ ] **Step 3: Implement** as dynamicFieldAccess.ml, dynamicOperators.ml and castDetect.ml lower it

- Field access on `Dynamic` (and class-typed receivers reached through a type that has no such
  field): `d.x` → `Runtime.getField(d, "x", <hash>, true)`, or `Runtime.getField_f` when the
  expression's type is like-float; `d.x = v` → `Runtime.setField` / `setField_f`; `d.f(a, b)` →
  `Runtime.callField(d, "f", <hash>, new object[]{a, b})` (null for no arguments), result
  converted. `Reflect.field(o, "const")`/`setField(o, "const", v)` with a constant name lower the
  same way with `throwErrors` false. `Runtime.getField` and friends test `obj as haxe.lang.HxObject`
  (the class) and otherwise fall back to `slowGetField` etc. through System.Reflection.
- Operators with a `Dynamic`, monomorph, type-parameter or `Null<T>` operand: `==`/`!=` →
  `Runtime.eq` (`Runtime.refEq` when neither side is basic, Dynamic, String or a type parameter;
  comparisons with literal `null` stay `ceq`); `+` → `Runtime.plus` (always a boxed double for
  numbers), or `Runtime.concat(Std.string(a), …)` when the result type is String; `<`, `<=`, `>`,
  `>=` → `Runtime.compare(a, b) <op> 0` (ordinal for strings); `* / - %` → both operands through
  `Runtime.toDouble` (`toInt` when the expression's type is Int); `& | ^ << >> >>>` → `toInt`;
  `&& ||` and `!` → `toBool`; unary `-` → `-Runtime.toDouble(a)`; `d++` → `d = Runtime.plus(d, 1)`
  stored as a double; `d += x` → `Runtime.plus`.
- Conversions: Dynamic → Int `Runtime.toInt` (Convert rounding, so 2.5 → 2), → Float
  `Runtime.toDouble`, → Bool `Runtime.toBool` (null → false), → String `Runtime.toString` (no type
  check); `cast` to a class → `castclass`; `cast` to a type parameter → `Runtime.genericCast<T>`;
  `Std.downcast(o, C)` → `isinst`; `Std.isOfType` inline as gencs.ml:242-300 writes it (`Float` →
  `o is double || o is int || o is uint`; `Int` → `o is int || o is uint || Runtime.isInt(o)`; class
  or enum → `isinst`; `Dynamic` → non-null).
- The runtime's `Runtime` methods these reach compile without stubs.

- [ ] **Step 4: Run all cases**

Run: the build command, then `tests/dotnet/run.sh …`
Expected: all `ok`.

- [ ] **Step 5: Commit**

```bash
git add src/hxc/codegen/dotnet tests/dotnet/cases.hx.txt
git commit -m "Lower Dynamic field access, operators and conversions to gencs's runtime calls"
```

---

### Task 7: Anonymous objects and `Null<T>`

**Files:**
- Modify: `src/hxc/codegen/dotnet/{TexprDynamic,TexprToIl,TclassToIl,DotnetTypes}.hx`, the runtime's `HxObject.hx` (`DynamicObject`), `Null.hx`
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: Task 6's `TexprDynamic`.
- Produces: `TObjectDecl` lowering; `Null<T>` operations; optional basic-typed arguments with
  default values (milestone 2's refusal "default argument values" goes away for them).

- [ ] **Step 1: Write the failing cases**

```
--- anonymous-objects @gencs
class P {
	static function main() {
		var o = {y: "a", x: 1, z: 2.5, bb: true, aa: [1]};
		Sys.println(Reflect.fields(o).join(","));
		Sys.println(o.x + o.z);
		o.x = 5;
		Sys.println(o.x);
		var d:Dynamic = o;
		d.x = "str";
		Sys.println(Reflect.fields(d).join(","));
		d.newf = 1;
		Sys.println(Reflect.fields(d).join(","));
		Sys.println(d.missing);
		var e = {};
		Sys.println(Reflect.fields(e).length);
		var count = 0;
		var side = {a: count++, b: count++};
		Sys.println(side.a + "," + side.b);
	}
}
===
--- hash-collision @gencs
class P {
	static function main() {
		var d:Dynamic = {};
		Reflect.setField(d, "<first name of the colliding pair>", 1);
		Reflect.setField(d, "<second name>", 2);
		Sys.println(Reflect.field(d, "<first name>") + " " + Reflect.field(d, "<second name>"));
		Sys.println(Reflect.fields(d).length);
	}
}
===
--- null-of-basic-types @gencs
class P {
	static function opt(a:Int, ?b:Int, c:Float = 2.5):String {
		return a + "," + b + "," + c;
	}
	static function main() {
		var ni:Null<Int> = null;
		Sys.println(ni == null);
		ni = 5;
		Sys.println(ni + 1);
		ni++;
		Sys.println(ni);
		var nf:Null<Float> = ni;
		Sys.println(nf);
		var d:Dynamic = ni;
		Sys.println(d);
		Sys.println(opt(1));
		Sys.println(opt(1, 2, 3));
		var e = [1, 2, 3];
		e.pop();
		Sys.println(e.pop());
		var empty:Array<Int> = [];
		Sys.println(empty.pop());
	}
}
===
```

Find the colliding pair for `hash-collision` with a script over `FieldHashes.hash`'s formula (two
ASCII identifiers with the same 31-bit hash) and put it in the case.

- [ ] **Step 2: Run them to see them fail**

Run: `tests/dotnet/run.sh … --case anonymous-objects`
Expected: FAIL.

- [ ] **Step 3: Implement** as objectDeclMap.ml/reflectionCFs.ml and hardNullableSynf.ml do

- `{f: v, …}` → `new haxe.lang.DynamicObject(int[] hashes, object[] dynamics, int[] hashes_f, double[] dynamics_f)`:
  like-float fields (Int, Float, UInt; not Int64) go into the `_f` pair as doubles, the rest boxed
  into `dynamics`; each pair sorted by hash ascending; values that aren't side-effect free are
  evaluated first, in source order, into temporaries. `{}` passes four empty arrays.
- Reads and writes of anonymous-typed fields go through `Runtime.getField_f` / `getField` (true) and
  `setField_f` / `setField` by the field's type, with compile-time hashes.
- The runtime's `DynamicObject` keeps hxcs's behavior: `__hx_getFields` lists dynamic hashes
  ascending, then float hashes, then conflict names; a set moves a field out of the float pair
  unless the value is a Float; `getField` ignores `throwErrors` (missing → null, or
  `Runtime.undefined` when checking); conflicts use negative hashes and `FieldHashConflict`.
- `Null<T>` (`haxe.lang.Null`1`, a struct with `value` and `hasValue`): `x == null` → `!x.hasValue`;
  from `T` → `new Null<T>(v, true)`; `null` → `default(Null<T>)`; read as `T` → `x.value` (0 when
  empty); arithmetic on `x.value`; `x++` → `(x = new Null<T>(x.value + 1, true)).value`;
  `Null<Int>` → `Null<Float>` converts with a `hasValue` check; `==` between two nullables or with a
  number → `Runtime.eq(x.toDynamic(), …)`; to Dynamic, `Std.string` or string concatenation →
  `x.toDynamic()` (a boxed `T` or null, never a boxed struct); from Dynamic →
  `Null<object>.ofDynamic<T>(d)`.
- Optional arguments of basic types are `Null<T>` parameters; the default is applied at the top of
  the body (`double c1 = !c.hasValue ? 2.5 : c.value`), and a call omitting them passes
  `default(Null<T>)`.
- `Array.pop`/`shift` compile without stubs now.

- [ ] **Step 4: Run all cases**

Run: the build command, then `tests/dotnet/run.sh …`
Expected: all `ok`.

- [ ] **Step 5: Commit**

```bash
git add src/hxc/codegen/dotnet tests/dotnet/cases.hx.txt
git commit -m "Lower anonymous objects and Null<T> as gencs does"
```

---

### Task 8: Plan exit check

**Files:**
- Modify: `README.md`, `tests/dotnet/cases.hx.txt`

- [ ] **Step 1: Check the runtime's stub report**

Run: `<hxc> -cp . --main P --cs out -D dotnet -D dotnet-stub-report` on `hello`.
Expected: no line names `haxe.lang.FieldLookup`, `haxe.lang.HxObject`, `haxe.lang.DynamicObject`,
`haxe.lang.Null` or the `Runtime` members Tasks 5-7 use (`getField*`, `setField*`, `callField`,
`slow*`, `eq`, `refEq`, `plus`, `compare`, `concat`, `toInt`, `toDouble`, `toBool`, `toString`,
`isInt`, `genericCast`, `unbox`, `mkNullable`). Lines for closures, enums and `Std`/`Type` helpers
remain for plan 3b. Record the report's line count in the commit body.

- [ ] **Step 2: Run everything**

Run: the build command; `tests/dotnet/run.sh …` (all cases); hxc's own families; the conformance
suite (`neko run.n run --compiler … --std C:/HaxeToolkit/haxe/std --divergences D:/_github/hxc/tests/divergences.json -j 4`).
Expected: all cases `ok`; families 110/0; conformance as before this branch (the 2 known
environment-specific failures at most).

- [ ] **Step 3: Document**

README `.NET output`: what now works (classes with reflection, `Dynamic`, anonymous objects,
`Null<T>`), what still compiles to stubs (closures, enums, …, until plan 3b), and that hxc ships its
own hxcs runtime (`<hxc-dotnet-runtime>/` in messages) which can't be overridden through the class
path.

- [ ] **Step 4: Commit**

```bash
git add README.md tests/dotnet/cases.hx.txt
git commit -m "Document the .NET runtime foundation"
```

---

## Left for plans 3b and 3c

- 3b: local functions and closure classes (`<Class>_<field>_<line>__Fun`, captured-variable
  wrapping), method closures as values, dynamic methods, `Reflect.makeVarArgs`; enums
  (`haxe.lang.Enum`, per-constructor classes, `_hx_index` switches, the `Type` enum API);
  `Std`/`Type`/`Reflect` completeness (`resolveClass`, `getClassName`, `getInstanceFields`,
  `typeof`, `parseInt`/`parseFloat`); `haxe.Exception` throws and catches; the `haxe.Serializer`
  corpus round-tripped both ways (`D:/_hxcm3harness/ser/S.hx` is the starting point).
- 3c: generic hxgen classes' companion interfaces and `__hx_cast`; the `Array` forwarding fix for
  Haxe issue 8314 with its divergence records.
