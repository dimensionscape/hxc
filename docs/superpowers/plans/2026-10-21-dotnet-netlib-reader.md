# .NET assembly reader (`--net-lib` / `--net-std`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** hxc reads .NET assemblies the way Haxe 4.3.7 does, so `--cs` code that uses .NET types
type-checks with the same diagnostics as Haxe 4.3.7, the server app included.

**Architecture:** a port of Haxe 4.3.7's `libs/ilib` (PE and ECMA-335 metadata reader) and
`src/codegen/dotnet.ml` (IL classes → Haxe extern declarations) into `src/hxc/codegen/dotnet/`. It
is shaped like the existing `--java-lib` loader in `src/hxc/codegen/java/`: a library object indexes
the assembly when it loads and converts a type only when the typer asks for it, through
`ctx.loadExternType`. Every behavior is checked against Haxe 4.3.7 with haxe-conformance case
families.

**Tech Stack:** Haxe 4.3 (hxc's own source), hxcpp via Aedifex, the haxe-conformance harness, and
the .NET 10 SDK (only to build the test fixture DLLs).

**Spec:** `docs/superpowers/specs/2026-10-21-dotnet10-il-generator-design.md`. This plan is
milestone 1, *"`--net-lib` / `--net-std` reader"*.

**Port source:** Haxe tag `4.3.7` (commit `e0b355c`), the same one haxe-conformance pins:
`libs/ilib/{peData.ml,peReader.ml,ilData.mli,ilMeta.mli,ilMetaReader.ml,ilMetaTools.ml}`,
`src/codegen/dotnet.ml`, `src/context/nativeLibraryHandler.ml`, the `Cs` case of `get_config` in
`src/context/common.ml` (lines 677-704), and `loop_lib … "hxcs"` in `src/compiler/compiler.ml`
(line 589). Raw files are at `https://raw.githubusercontent.com/HaxeFoundation/haxe/4.3.7/<path>`.
Put downloads in a scratch directory outside the repo; they are GPL reference material, not
sources to commit.

## Global Constraints

- The oracle is Haxe 4.3.7 with **hxcs 4.2.0**. Record expectations with exactly that pair; CI
  installs `hxcs 4.2.0`.
- Code lives under `src/hxc/codegen/dotnet/`. Follow `src/hxc/codegen/java/` for naming, comment
  density and idiom: short `//` comments that state behavior, no doc banners.
- Read lazily, like `JavaLibrary`: an assembly's metadata is read on `load()`, and a class is
  converted only on `build()`. The server app loads 63 std DLLs plus 5 libs on every compile.
- Never reach the network or the .NET runtime from hxc. The reader is pure Haxe over `haxe.io.Bytes`.
- Determinism: anything that iterates a map to produce output or diagnostics iterates in a fixed
  order (insertion or sorted), never hash order.
- Commit messages follow the repo's style (an imperative sentence, a body that explains why) and end
  with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **A type defined in two loaded libraries** must resolve to the same library Haxe 4.3.7 picks.
   `lookup_ilclass` folds right over `net_libs`, and the order of `com.load_extern_type` decides
   `build`. Test: `two-libraries-same-type` in Task 2.
2. **Real std folders** (hxcs `netlib/net-40`, and the server app's `res/netcore-dlls/net-40` with .NET 5
   reference assemblies and type forwarders) must load without a crash and resolve `cs.system.*`
   types. Test: `net40-std-loads` in Task 2 (hxcs), and Task 5 Step 1 (the server app's folder).
3. **Non-public and compiler-generated types** (`internal` classes, lambda closure classes such as
   `<>c`, `<PrivateImplementationDetails>`) must be skipped exactly as `is_compiler_generated` and
   the visibility checks do. Test: `internal-type-is-not-found` in Task 2.
4. **Escaped names that collide**: a top-level `Outer_Inner` next to the nested `Outer.Inner`, and a
   nested type inside a generic (`Box`1+Nested`). Test: `nested-name-collision`,
   `nested-in-generic` in Task 3.
5. **Overloads and byref parameters**: calling the wrong `F` overload, or passing a plain `Int` to a
   `ref int` parameter, must give Haxe's exact error. Test: `overload-mismatch-error`,
   `ref-parameter-needs-cs-ref` in Task 4.

---

## Setup (once per machine, not a task)

```bash
# build hxc (C++; several minutes)
cd D:/_github/hxc && haxelib run aedifex build cpp .
export HXC="$(ls D:/_github/hxc/bin/cpp/*/*/release/bin/hxc* | head -1)"
export HAXE_STD_PATH="$(dirname "$(command -v haxe)")/std"
# the harness, at the commit CI pins
git clone https://github.com/dimensionscape/haxe-conformance.git D:/_github/haxe-conformance
git -C D:/_github/haxe-conformance checkout 4349f29f713ae367fcb0407beb95d27ea02e466c
# the oracle pair: Haxe 4.3.7 + hxcs 4.2.0 (note the active hxcs first and switch back afterwards;
# the server app builds use it)
haxelib list hxcs
haxelib install hxcs 4.2.0 --always && haxelib set hxcs 4.2.0 --always
```

**Run a family against hxc** (from `D:/_github/haxe-conformance`):

```bash
neko run.n run --compiler "$HXC" --std "$HAXE_STD_PATH" \
  --cases D:/_github/hxc/tests/cases --expected D:/_github/hxc/tests/expected --family <name>
```

**Record a family from Haxe 4.3.7** (same directory; writes `tests/expected/<name>.json`):

```bash
neko run.n record --compiler haxe --std "$HAXE_STD_PATH" \
  --cases D:/_github/hxc/tests/cases --expected D:/_github/hxc/tests/expected --family <name>
```

Every task below records first, then runs. A case "fails" when hxc's output differs from the
recording.

---

### Task 1: The `cs` target's setup (hxcs, platform config, .NET defines, std resolution)

**Files:**
- Create: `src/hxc/codegen/dotnet/NetSetup.hx`
- Modify: `src/hxc/Compiler.hx` (the `--jvm/--java` → `-lib hxjava` rewrite near line 4479; the
  ignored-options list near line 818; the per-target define block near line 975; the
  `registerNativeLibs` call near line 1010)
- Modify: `src/hxc/context/PlatformConfig.hx` (add `cs()`, route `Cs` in `get`)
- Modify: `src/hxc/context/Context.hx` (new fields)
- Modify: `.github/actions/setup-tests/action.yml`, `.github/workflows/ci.yml` (the "hxc's own tests"
  step)
- Test: `tests/cases/cs-target/family.json`, `tests/cases/cs-target/cases.hx.txt`,
  `tests/expected/cs-target.json`

**Interfaces:**
- Produces: `Context.netStd:Array<String>` (the `--net-std` paths in command-line order),
  `Context.netStdFiles:Array<String>` (the std DLLs found, in directory-read order; Task 2 loads
  them), `NetSetup.beforeGenerate(ctx:Context):Void`, `PlatformConfig.cs():PlatformConfig`.

- [ ] **Step 1: Write the failing cases**

`tests/cases/cs-target/family.json`:

```json
{
	"name": "cs-target",
	"oracle": "haxe",
	"kind": "compile-diff",
	"cost": "quick",
	"module": "P",
	"args": ["-cp", ".", "$module", "--cs", "$out", "--no-output"]
}
```

`tests/cases/cs-target/cases.hx.txt`:

```
--- default-net-ver-is-20
class P { static function main() { #if (NET_20 && !NET_21) $type("net20"); #end #if net $type("net"); #end } }

--- net-ver-40-defines-up-to-40 + -D net-ver=40
class P { static function main() { #if (NET_40 && !NET_45) $type("net40"); #end } }

--- net-ver-not-a-number + -D net-ver=4x
class P { static function main() {} }

--- net-ver-below-20 + -D net-ver=10
class P { static function main() {} }

--- no-std-dir-for-net-ver + -D net-ver=99
class P { static function main() {} }

--- netcore-without-netcore-ver + -D net-target=netcore
class P { static function main() {} }

--- net-std-without-the-digraph + --net-std . -D net-ver=40
class P { static function main() {} }
```

- [ ] **Step 2: Record and run; see it fail**

Record `cs-target`, then run it. Expected: the define cases and the four error cases FAIL: hxc
defines none of `NET_*`/`net` and raises none of the errors. Also check that `--cs` currently
skips `-lib hxcs`.

- [ ] **Step 3: Implement**

- In `Compiler.hx`'s `processParams`, rewrite `--cs`/`-cs <dir>` to push the pair and then
  `-lib hxcs`, the same as the `hxjava` rewrite. This is Haxe's `loop_lib arg dir "hxcs"`.
- `PlatformConfig.cs()`, from Haxe's `get_config` `Cs` case:
  - `isStatic: true, sys: true, supportsOverload: true, capturePolicy: CPWrapRef, padNulls: true,
    addFinalReturn: false, canSkipNonNullableArgument: true, supportsRestArgs: true, usesUtf16: true,
    supportsUnicode: true, supportsThreads: true, supportsAtomics: true`;
  - then `thisBeforeSuper = false`;
  - `nativeThrows` and `nativeCatches` = `["cs.system.Exception", "haxe.Exception"]`;
  - `wildcardCatch` and `baseThrow` = `"cs.system.Exception"`.

  In `get`, route `case Cs: cs();`.
- `NetSetup.beforeGenerate(ctx)` ports `Dotnet.before_generate` (dotnet.ml 1245-1321), keeping
  its error texts verbatim:
  - net-ver parsing and the default (`47` when `netcore-ver` is set, else `20`);
  - the `NET_20…NET_50` loop and `net_target`;
  - the `net-<ver>` / `netcore-<ver>` digraph search over `ctx.netStd`, or `["netlib"]` when empty,
    each entry resolved like `Common.find_file` (as is, then against the class path);
  - collecting every `*.dll` in each matched directory into `ctx.netStdFiles`.

  Call it in `Compiler.hx`'s per-target define block when `platform == Cs`, where `java_ver` is
  handled.
- Move `-net-std`/`--net-std` out of the ignored-options list: append the value to `ctx.netStd`.
  `-net-lib` stays ignored until Task 2.
- CI: in `setup-tests/action.yml`, add `haxelib install hxcs 4.2.0 --always --quiet` beside hxjava.
  In `ci.yml`'s "hxc's own tests" step, add `--expected "$GITHUB_WORKSPACE/tests/expected"`.

- [ ] **Step 4: Rebuild hxc, run `cs-target`; expect PASS.** Also run the `determinism` and
  `haxe-defects` families. Expect PASS, unchanged.

- [ ] **Step 5: Commit**

```bash
git add src/hxc/codegen/dotnet/NetSetup.hx src/hxc/Compiler.hx src/hxc/context/PlatformConfig.hx \
  src/hxc/context/Context.hx .github tests/cases/cs-target tests/expected/cs-target.json
git commit   # "Set up the cs target as Haxe 4.3.7 does"
```

---

### Task 2: Read assemblies and convert plain classes

**Files:**
- Create: `src/hxc/codegen/dotnet/PeData.hx`, `PeReader.hx` (ports `peData.ml`, `peReader.ml`:
  DOS/PE/optional headers, section table, data directories, CLI header, RVA → file offset)
- Create: `src/hxc/codegen/dotnet/IlMeta.hx` (port `ilMeta.mli`: the raw table row types),
  `IlMetaReader.hx` (port `ilMetaReader.ml`: metadata root, the `#~`/`#-` `#Strings` `#US` `#Blob`
  `#GUID` streams, heap-size flags, row counts, coded indexes, every table, signature blobs)
- Create: `src/hxc/codegen/dotnet/IlData.hx` (port `ilData.mli`: the class model),
  `IlMetaTools.hx` (port `ilMetaTools.ml`: `get_path`, `convert_class`, signature normalization)
- Create: `src/hxc/codegen/dotnet/NetConverter.hx` (port `dotnet.ml` 1-1127: names, signatures, and
  `convert_ilclass`/`convert_ilfield`/`convert_ilmethod` for plain classes in this task)
- Create: `src/hxc/codegen/dotnet/NetLibrary.hx` (port `class net_library`, dotnet.ml 1131-1230)
- Modify: `src/hxc/Compiler.hx` (`-net-lib`/`--net-lib` into `nativeLibs`; `registerNativeLibs`
  accepts `Cs`, splitting `file@std` as `nativeLibraryHandler.ml` does)
- Modify: `src/hxc/codegen/dotnet/NetSetup.hx` (load `ctx.netStdFiles` as std libraries)
- Modify: `src/hxc/context/Context.hx` (`netLibs`, `netPathMap`)
- Create: `tests/fixtures/netlib/Fixture.csproj`, `tests/fixtures/netlib/Fixture.cs`,
  `tests/fixtures/netlib2/Fixture2.csproj`, `tests/fixtures/netlib2/Fixture2.cs`
- Test: `tests/cases/net-lib/family.json`, `cases.hx.txt`, `fixture/Fixture.dll`,
  `fixture/Fixture2.dll`, `tests/expected/net-lib.json`; new cases in `tests/cases/cs-target/`

**Interfaces:**
- Consumes: `Context.netStdFiles`, `NetSetup` (Task 1).
- Produces:
  - `IlData.IlPath = {ns:Array<String>, nested:Array<String>, name:String}`, `IlData.IlClass`
    (fields as in `ilData.mli`'s `ilclass`).
  - `NetConverter.NetLibCtx = {nstd:Bool, nil:IlData.IlCtx}`, the port of `net_lib_ctx`. Its
    `ncom` becomes the `Context` passed where needed.
  - `NetConverter.netpathToHx(std:Bool, p:IlPath):hxc.core.Globals.Path`.
  - `NetConverter.convertIlClass(lib:NetLibCtx, p:Position, cls:IlClass, delegate:Bool):hxc.ast.Ast.TypeDecl`.
  - `class NetLibrary` with `new(name:String, filePath:String, isStd:Bool)`, `isExtern:Bool`,
    `load():Void`, `lookup(path:Path):Null<IlClass>`,
    `build(path:Path, p:Position):Null<Array<TypeDecl>>` and `listModules():Array<Path>`.
  - `Context.netLibs:Array<NetLibrary>` (in add order).
  - `Context.netPathMap:Map<String, IlPath>`, keyed by `hxc.core.Globals.sTypePath(hxPath)`.
  - `NetSetup.addNetLib(ctx:Context, file:String, isStd:Bool, isExtern:Bool):Void`.

- [ ] **Step 1: Build the fixtures**

`tests/fixtures/netlib/Fixture.csproj`: `<TargetFramework>netstandard2.0</TargetFramework>`,
`<Deterministic>true</Deterministic>`, `<AssemblyName>Fixture</AssemblyName>`. `Fixture.cs` starts
with the comment `// Rebuild: dotnet build -c Release, then copy bin/Release/netstandard2.0/Fixture.dll
to tests/cases/net-lib/fixture/.`. It declares these (Tasks 3 and 4 add more to this same file and
rebuild):

```csharp
namespace Fixture {
	public class Plain {
		public Plain() {} public Plain(int x) {}
		public int Count; public readonly double Ratio; public static string Name = "p"; public const int Max = 10;
		public int Add(int a, int b) => a + b; public static long Wide(long v) => v;
		public byte[] Bytes() => null; public uint Unsigned() => 0; public object Any() => null;
	}
	internal class Hidden {}
	public class UsesLambda { public System.Func<int, int> F() => x => x + 1; }
}
namespace Fixture.Sub { public class Thing {} }
```

`Fixture2` (assembly `Fixture2`) declares `namespace Fixture { public class Plain { public int Other; } }`.
Build both, copy the DLLs into `tests/cases/net-lib/fixture/`.

- [ ] **Step 2: Write the failing cases**

`tests/cases/net-lib/family.json`: like `cs-target`, with `"name": "net-lib"` and
`"args": ["-cp", ".", "$module", "--cs", "$out", "--no-output", "-D", "net-ver=40", "--net-lib", "Fixture.dll"]`.
`net-ver=40` selects hxcs's `netlib/net-40`, which has `System.Core.dll`, home of the
`System.Func` types the fixture uses. `net-20` has only `mscorlib.dll` and `System.dll`.

`tests/cases/net-lib/cases.hx.txt`:

```
--- plain-class-members
class P { static function main() { var p = new fixture.Plain(3); $type(p.Count); $type(p.Ratio); $type(fixture.Plain.Name); $type(fixture.Plain.Max); $type(p.Add(1, 2)); $type(fixture.Plain.Wide); $type(p.Bytes()); $type(p.Unsigned()); $type(p.Any()); } }

--- namespace-is-lowercased
class P { static function main() { $type(new fixture.sub.Thing()); } }

--- internal-type-is-not-found
class P { static function main() { var h:fixture.Hidden = null; } }

--- lambda-closure-class-is-not-found
class P { static function main() { $type(new fixture.UsesLambda().F()); var c:fixture.UsesLambda_c = null; } }

--- assigning-a-readonly-field
class P { static function main() { new fixture.Plain().Ratio = 1.0; } }

--- two-libraries-same-type + --net-lib Fixture2.dll
class P { static function main() { var p = new fixture.Plain(); $type(p.Count); $type(p.Other); } }

--- missing-net-lib + --net-lib Missing.dll
class P { static function main() {} }

--- bad-std-suffix + --net-lib Fixture.dll@std@x
class P { static function main() {} }

--- net-lib-as-std + --net-lib Fixture2.dll@std
class P { static function main() { $type(new fixture.Plain().Other); } }
```

Append to `tests/cases/cs-target/cases.hx.txt`:

```
--- std-type-resolves
class P { static function main() { $type(new cs.system.text.StringBuilder()); } }

--- native-array-works
class P { static function main() { var a = new cs.NativeArray<Int>(3); $type(a); $type(a.Length); $type(a[0]); } }

--- net40-std-loads + -D net-ver=40
class P { static function main() { $type(cs.system.Console.Out); $type(cs.system.Environment.ProcessorCount); } }
```

- [ ] **Step 3: Record both families, read the recordings, and run them.** Before trusting a
  recording, read it. If Haxe reports `Type not found` for a path the case means to exercise, the
  case's Haxe path is wrong, not the converter. Find the path Haxe uses with
  `haxe -cp . P --cs out --no-output -D net-ver=40 --net-lib Fixture.dll -D net_loader_debug`, which
  prints `found <path>` for every type, then fix the case and record again. This rule applies to
  every recording in this plan. Expected on running: FAIL, since every type lookup gives
  `Type not found` and `missing-net-lib` / `bad-std-suffix` don't give Haxe's errors.

- [ ] **Step 4: Implement the reader**

`PeReader.read(bytes:haxe.io.Bytes):PeData.PeFile`, `PeReader.readClrHeader(pe:PeFile):PeData.ClrHeader`,
then `IlMetaReader.readMetaTables(pe:PeFile, clr:ClrHeader):IlData.IlCtx`. Port the OCaml
function by function, keeping its names in camelCase. Read from `haxe.io.Bytes` with explicit
little-endian helpers. Compressed integers and coded-index widths follow ECMA-335 §II.23.2 and
§II.24.2.6, as `ilMetaReader.ml` implements them.

- [ ] **Step 5: Implement the library and the conversion of plain classes**

- `NetLibrary.load()` ports `method load`: it fills `netPathMap` and the typedef table, keyed by
  IL path.
- `lookup` ports `method lookup`: `hxpath_to_net` → `IlMetaTools.convertClass` → `normalize_ilcls`,
  cached per path, `null` cached too.
- `build` ports `method build`, including `["haxe","root"]` → `[]` and the `p.pfile` text
  `filePath + " @ " + sTypePath(path)`.
- `NetConverter` ports `netname_to_hx`, `netcl_to_hx`, `netpath_to_hx`, `add_cs`, `escape_chars`,
  `mk_type_path`, `convert_signature`, `convert_ilfield`, `convert_ilmethod`, `convert_ilclass`, and
  the helpers they call, producing the same metas (`@:native`, `@:libType`, `@:csNative`, `@:final`,
  `@:overload`, …) that dotnet.ml emits.
- `NetSetup.addNetLib` ports `add_net_lib` (with the `".NET lib " + file + " not found"` error)
  and registers `{name: filePath, load: lib.build}` on `ctx.loadExternType`, like
  `registerNativeLibs` does for Java.
- Libraries are added in the same order Haxe adds them: std DLLs from `beforeGenerate` first, then
  command-line `--net-lib`s in order (`create_typer_context`, compiler.ml line 172). Lookup
  precedence follows `lookup_ilclass`'s `fold_right`.
- Lookup is by Haxe path across every loaded library, not by assembly reference. Exported types
  (type forwarders) have no TypeDef row and are simply not indexed. That is how the spec's
  "type forwarding" requirement is met for type-checking; `net40-std-loads` covers it.

- [ ] **Step 6: Rebuild, run `net-lib` and `cs-target`; expect PASS.** If a diff remains,
  compare against the OCaml for the function that produced the text before changing anything else.

- [ ] **Step 7: Commit** the reader, the converter, the fixtures (sources and DLLs), the cases and
  the recordings. Message: "Read .NET assemblies for --net-lib and --net-std".

---

### Task 3: Names: generics, nested types, escaping

**Files:**
- Modify: `src/hxc/codegen/dotnet/NetConverter.hx`, `tests/fixtures/netlib/Fixture.cs`,
  `tests/cases/net-lib/fixture/Fixture.dll`
- Test: `tests/cases/net-lib/cases.hx.txt`, `tests/expected/net-lib.json`

**Interfaces:**
- Consumes: `NetConverter.netpathToHx`, `NetLibrary.build` (Task 2).
- Produces: no new names. It completes generic parameters and nested-type output in
  `convertIlClass`.

- [ ] **Step 1: Extend the fixture** (inside `namespace Fixture`), then rebuild and copy:

```csharp
public class Box<T> { public T Value; public U Map<U>(System.Func<T, U> f) => default; public class Nested { public T Item; } }
public class Pair<A, B> where A : class where B : struct { public A First; public B Second; }
public class Outer { public class Inner { public int V; } }
public class Outer_Inner { public string W; }
public class lowerName { public int X; }
public class Keywords { public int @in; public void @cast() {} public int @var; }
```

- [ ] **Step 2: Write the failing cases**

```
--- generic-class-and-method
class P { static function main() { var b = new fixture.Box_1<String>(); $type(b.Value); $type(b.Map); } }

--- generic-constraints
class P { static function main() { var p = new fixture.Pair_2<String, Int>(); $type(p.First); $type(p.Second); } }

--- nested-type-in-outer-module
class P { static function main() { var i = new fixture.Outer.Outer_Inner(); $type(i.V); } }

--- nested-name-collision
class P { static function main() { $type(new fixture.Outer_Inner().W); } }

--- nested-in-generic
class P { static function main() { var n = new fixture.Box_1.Box_1_Nested<Int>(); $type(n.Item); } }

--- lowercase-class-is-capitalized
class P { static function main() { $type(new fixture.LowerName().X); } }

--- haxe-keyword-members
class P { static function main() { var k = new fixture.Keywords(); $type(k); } }
```

- [ ] **Step 3: Record and run; expect FAIL** on whatever Task 2 didn't already port. A case that
  already passes is fine. Keep it as a regression check.

- [ ] **Step 4: Implement** whatever of `netcl_to_hx`'s backtick split, `netpath_to_hx`'s nested
  branch, `mk_type_path`'s `tsub`, and the type-parameter and constraint conversion in
  `convert_ilclass` / `convert_ilmethod` is missing. Keyword handling follows `is_haxe_keyword`
  exactly.

- [ ] **Step 5: Rebuild, run `net-lib`; expect PASS.**

- [ ] **Step 6: Commit** — "Name generic and nested .NET types as Haxe 4.3.7 does".

---

### Task 4: Members: properties, events, delegates, enums, interfaces, structs, operators, overloads, byrefs

**Files:**
- Modify: `src/hxc/codegen/dotnet/NetConverter.hx` (port `convert_ilprop`, `convert_ilevent`,
  `convert_delegate`, `convert_ilenum`, the operator tables `cs_binops`/`cs_unops`, explicit
  interface implementations, struct handling), `tests/fixtures/netlib/Fixture.cs`, the fixture DLL
- Test: `tests/cases/net-lib/cases.hx.txt`, `tests/expected/net-lib.json`

**Interfaces:**
- Consumes: Tasks 2-3.
- Produces: `NetConverter.convertDelegate(lib:NetLibCtx, p:Position, cls:IlClass):TypeDecl` and
  `NetConverter.convertIlEnum(lib:NetLibCtx, p:Position, cls:IlClass, isFlag:Bool):TypeDecl`.
  `NetLibrary.build` emits both the class and the delegate for sealed `System.MulticastDelegate`
  subclasses, as dotnet.ml 1200-1210 does.

- [ ] **Step 1: Extend the fixture**, then rebuild and copy:

```csharp
public interface IShape { double Area(); }
public interface INamed { string Name(); }
public class Square : IShape, INamed { public double Area() => 0; string INamed.Name() => "sq"; }
public enum Color { Red, Green = 5 }
[System.Flags] public enum Perm { None = 0, Read = 1, Write = 2 }
public delegate int Op(int a, int b);
public class Events { public event Op Fired; public int Size { get; set; } public int ReadOnly { get { return 1; } } public string this[int i] { get => null; set {} } }
public class Overloads { public void F(int a) {} public void F(string a) {} public void F(int a, int b) {} }
public struct Point { public int X; public Point(int x) { X = x; } }
public class Ops { public static Ops operator +(Ops a, Ops b) => a; public static bool operator ==(Ops a, Ops b) => true; public static bool operator !=(Ops a, Ops b) => false; public override bool Equals(object o) => true; public override int GetHashCode() => 0; }
public class ByRef { public void Fill(ref int a, out string b) { b = null; } }
public class Nulls { public int? MaybeInt; public System.Nullable<double> MaybeDouble; }
```

- [ ] **Step 2: Write the failing cases**

```
--- interface-and-explicit-impl
class P { static function main() { var s = new fixture.Square(); $type(s.Area()); var i:fixture.IShape = s; var n:fixture.INamed = s; $type(n.Name()); } }

--- enum-values
class P { static function main() { $type(fixture.Color.Green); var c:fixture.Color = Red; } }

--- flags-enum
class P { static function main() { $type(fixture.Perm.Read); } }

--- delegate-type
class P { static function main() { var o:fixture.Op = null; $type(o); $type(o.Invoke); } }

--- event-and-properties
class P { static function main() { var e = new fixture.Events(); $type(e.Size); e.Size = 2; $type(e.ReadOnly); $type(e.Fired); $type(e.get_Item); } }

--- assigning-a-get-only-property
class P { static function main() { new fixture.Events().ReadOnly = 2; } }

--- overloads-resolve
class P { static function main() { var o = new fixture.Overloads(); o.F(1); o.F("a"); o.F(1, 2); $type(o.F); } }

--- overload-mismatch-error
class P { static function main() { new fixture.Overloads().F(1.5); } }

--- struct-type
class P { static function main() { var p = new fixture.Point(3); $type(p.X); } }

--- operators
class P { static function main() { var a = new fixture.Ops(); $type(a + a); $type(a == a); } }

--- ref-and-out-parameters
class P { static function main() { var a = 1; var b:String = null; new fixture.ByRef().Fill(a, b); $type(new fixture.ByRef().Fill); } }

--- ref-parameter-needs-cs-ref
class P { static function main() { new fixture.ByRef().Fill(1, null); } }

--- nullable-value-fields
class P { static function main() { var n = new fixture.Nulls(); $type(n.MaybeInt); $type(n.MaybeDouble); } }
```

- [ ] **Step 3: Record and run; expect FAIL** on the members not ported yet.

- [ ] **Step 4: Implement** the remaining `dotnet.ml` conversions, keeping their metas, accessor
  names, and the `@:skipReflection` / `@:event` / `@:delegate` markers the typer already knows
  (`src/hxc/data/Metas.hx`). If a diff points into the typer rather than the converter (overload
  resolution, operator lookup), fix it there, and check that the change doesn't move the `jvm`
  results (run the families that cover overloads, `overload-resolution` in haxe-conformance's own
  `cases/`, with `--family overload-resolution` and no `--cases`).

- [ ] **Step 5: Rebuild, run `net-lib`, `cs-target` and haxe-conformance's `overload-resolution`;
  expect PASS.**

- [ ] **Step 6: Commit** — "Convert .NET properties, events, delegates, enums and overloads".

---

### Task 5: The server app type-checks like Haxe 4.3.7

Exit criterion for this milestone. This runs locally, not in CI, because it needs the server app's checkout
and libraries. The server app is only read: nothing is written into it.

**Files:**
- Modify: whatever the diffs point at, in `src/hxc/`
- Test: one new case per fix, in the family that owns the behavior (`net-lib`, `cs-target`, or a
  new family named after the feature), recorded from Haxe 4.3.7

**Interfaces:**
- Consumes: everything above.
- Produces: nothing new.

- [ ] **Step 1: Capture both outputs**

```bash
cd <server-app>/haxe
haxe serverCompile.hxml --no-output > "$SCRATCH/haxe.txt" 2>&1; echo "haxe exit $?"
"$HXC" serverCompile.hxml --no-output > "$SCRATCH/hxc.txt" 2>&1; echo "hxc exit $?"
diff "$SCRATCH/haxe.txt" "$SCRATCH/hxc.txt"
```

`$SCRATCH` is a directory outside both repos. The server app's builds expect its usual hxcs: run this with
the hxcs that the server app normally uses active, and record/run hxc's families with hxcs 4.2.0.

Expected the first time: differences. Haxe's own output is the target, warnings and all.

- [ ] **Step 2: For each difference, smallest-first**
  - reduce it to a case of a few lines that shows the same difference (using the fixture DLLs, or
    `--net-std` to hxcs's `net-40` for framework types);
  - add the case to the owning family, record it, and watch it fail;
  - fix it in hxc, and watch the case and every family touched so far pass;
  - commit with a message naming the behavior (e.g. "Convert .NET indexers with several
    parameters").

- [ ] **Step 3: Repeat Step 1 until `diff` prints nothing and both exit codes match.** Then do the
  same with the server app's `serverCompile-Core.hxml` and `serverCompile-Reports.hxml`, if Builder.hx has
  written them on this machine.

- [ ] **Step 4: Run everything once more**: `cs-target`, `net-lib`, `determinism`, `haxe-defects`,
  and haxe-conformance's default families with `--divergences D:/_github/hxc/tests/divergences.json`.
  Expect PASS, apart from divergences already listed.

---

## Later plans (one per milestone, written when the previous one lands)

2. Writers + minimal emitter: metadata tables/heaps, PE writer, IL encoder; `--cs <dir> -D dotnet`
   writes a runnable, ILVerify-clean, deterministic DLL.
3. Runtime parity: hxc's copy of the `std/cs` runtime compiled by the generator, the `__rethrow__`
   special throw (`ec_special_throw` in the `Cs` config), Serializer/reflection parity with a
   differential suite against Haxe 4.3.7 gencs and a serialized-value corpus.
4. Interop: `@:nativeGen`, attributes, properties, nullability metadata, delegates/events, the
   inline-C# subset, manifest resources; the server app builds to `HaxeServer.dll`.
5. Portable PDB.
6. The server app acceptance: the two-way test-database migration.
