# .NET writers and minimal emitter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `--cs <dir> -D dotnet` writes a .NET 10 assembly that runs on `dotnet`, passes ILVerify and
is byte-identical across compiles, for programs with classes, statics, strings, arrays and
exceptions.

**Architecture:** new files in `src/hxc/codegen/dotnet/`, next to milestone 1's reader. Two layers,
shaped like the JVM backend: format writers that know ECMA-335 and PE but not Haxe (`IlBytes`,
`MetaHeaps`, `MetaTables`, `SigWriter`, `IlCode`, `PeWriter`, `ModuleBuilder`, the counterparts of
`JvmWriter`/`JvmConstantPool`/`JvmCode`/`JvmClass`), and an emitter that walks the typed AST
(`GenerateDotnet`, `TclassToIl`, `TexprToIl`, the counterparts of `GenerateJvm`/`TclassToJvm`/
`TexprToJvm`). Signatures use milestone 1's `IlSigNorm` as the type model, so references to
`--net-lib` members reuse the reader's signatures as they are. hxcs's runtime (`cs.internal.*`,
kept by `@:keep` and full of inline C#) is milestone 3's job, so this milestone emits standard-library
code it can lower and stubs the rest, under a rule written down in Task 2.

**Tech Stack:** Haxe 4.3 (hxc's own source), hxcpp via Aedifex, the .NET 10 SDK (to run output and
to build the C# checker tool), `Microsoft.ILVerification` 10.0.13 (inside the checker tool only).

**Spec:** `docs/superpowers/specs/2026-10-21-dotnet10-il-generator-design.md`, milestone 2,
*"Writers + minimal emitter"*. Read *How it gets made*, *Compatibility* and *Constraints* before
starting.

**Reference for CLR naming and lowering choices:** Haxe 4.3.7's `src/generators/gencs.ml` (raw at
`https://raw.githubusercontent.com/HaxeFoundation/haxe/4.3.7/src/generators/gencs.ml`). Put it in a
scratch directory outside the repo; it is GPL reference material, not a source to commit. Line
numbers below are from that file.

**Branch:** `git switch -c dotnet-il-m2 dotnet-il-generator`. Milestone 1 lives only on
`dotnet-il-generator` (local, never pushed). Don't push either branch or open a PR; the person
driving this does that.

## Global Constraints

- Output is one PE32, IL-only, AnyCPU assembly per compile, targeting `net10.0`. No C# source output,
  no .NET Framework or Mono.
- `--cs <dir>` together with `-D dotnet` selects this generator. The platform stays `cs`. `--cs`
  without `-D dotnet` keeps today's behavior (type-check, write nothing).
- Assembly name: `-D dll-name=<name>` when given, otherwise the output directory's last segment.
  Files are `<dir>/<name>.dll`, plus `<dir>/<name>.runtimeconfig.json` when there is a `-main`.
- Same inputs give byte-identical DLL and runtimeconfig: content-derived MVID and timestamp, no
  wall-clock time, no absolute paths in the image, no hash-order iteration.
- hxc writes the PE, metadata and IL itself, in Haxe over `haxe.io.Bytes`. hxc never calls the .NET
  runtime, `System.Reflection.Metadata`, or the network.
- CLR names follow gencs (spec *Compatibility*): namespaces, type names with generic arity, member
  names and modifiers as Task 2 and Task 4 pin them.
- Invalid IL is caught at test time: every test assembly goes through ILVerify. A construct the
  generator can't lower is a compile error in user code, never a silent miscompile.
- Code under `src/hxc/codegen/dotnet/` follows `src/hxc/codegen/jvm/`: short `//` comments that state
  behavior, no doc banners, hxc naming.
- Commit messages follow the repo's style (an imperative sentence, a body that explains why) and end
  with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Shift counts of 32 or more** must behave as gencs output does (C# masks the count with `& 31`):
   `1 << 33` is `2`. Test: `int-arithmetic` in Task 3.
2. **NaN in comparisons**: `nan >= 1`, `nan <= 1` and `nan == nan` are false, `!(nan < 1)` is true.
   A naive `clt` + invert gets `>=` wrong. Test: `float-compare-nan` in Task 3.
3. **Extern constants** (`Int32.MaxValue`, `Double.NaN`) are literal fields with no storage; `ldsfld`
   on them throws at run time. They must be inlined from the metadata Constant. Test:
   `extern-const` in Task 2, `float-compare-nan` in Task 3.
4. **Methods past the tiny-header limits**: more than 255 locals (`ldloc` long form), max stack
   above 8, code of 64 bytes or more. Test: `many-locals-and-deep-stack` in Task 3.
5. **A `try` reached with values already on the stack** (`1 + (try f() catch (e:E) 0)`): IL requires
   an empty stack on entry to a protected region. Test: `exceptions` in Task 6.

---

## File structure

| File | Responsibility |
| --- | --- |
| `src/hxc/codegen/dotnet/IlBytes.hx` | Growable little-endian byte buffer, ECMA compressed integers, patching |
| `src/hxc/codegen/dotnet/MetaHeaps.hx` | `#Strings`, `#US`, `#Blob`, `#GUID` heaps with dedupe |
| `src/hxc/codegen/dotnet/MetaTables.hx` | Row types of the tables written, coded indices, sorting, `#~` stream, metadata root |
| `src/hxc/codegen/dotnet/SigWriter.hx` | Blob signatures from `IlSigNorm` |
| `src/hxc/codegen/dotnet/IlCode.hx` | IL opcodes, labels, branch fixups, stack tracking, exception clauses, method bodies |
| `src/hxc/codegen/dotnet/PeWriter.hx` | PE32 image: headers, `.text`, `.reloc`, deterministic MVID and timestamp |
| `src/hxc/codegen/dotnet/ModuleBuilder.hx` | The assembly under construction: rows, tokens, TypeRef/MemberRef/TypeSpec dedupe |
| `src/hxc/codegen/dotnet/DotnetNames.hx` | gencs-compatible CLR names |
| `src/hxc/codegen/dotnet/DotnetTypes.hx` | Haxe `Type` → `IlSigNorm`, extern paths and their assemblies, `Unsupported` |
| `src/hxc/codegen/dotnet/ExternMembers.hx` | Resolves extern fields, properties, constants and overloads to IL members |
| `src/hxc/codegen/dotnet/TclassToIl.hx` | Declares classes/interfaces (TypeDef, fields, methods) and emits their bodies |
| `src/hxc/codegen/dotnet/TexprToIl.hx` | Expression lowering |
| `src/hxc/codegen/dotnet/GenerateDotnet.hx` | Entry point: naming, output files, entry point method, stubs, stub report |
| `src/hxc/codegen/dotnet/NetLibrary.hx` (modify) | Assembly identity, whether the library defines a path |
| `src/hxc/Compiler.hx` (modify, ~line 1706) | Dispatch to `GenerateDotnet.generate` |
| `tests/fixtures/hxccheck/` | C# tool: `verify` (ILVerify) and `dump` (canonical metadata text) |
| `tests/dotnet/run.sh` | Compiles, verifies, checks determinism, runs and compares every case |
| `tests/dotnet/cases.hx.txt` | The cases, in haxe-conformance's case format plus a few header flags |
| `.github/workflows/ci.yml` (modify) | A `dotnet` job |
| `README.md` (modify) | `-D dotnet` usage and status |

---

### Task 1: Test harness, writers, and an empty assembly

The writers come first with the harness that checks them. Nothing is emitted for Haxe types yet:
the assembly holds the `<Module>` type, a Module row and an Assembly row.

**Files:**
- Create: `tests/fixtures/hxccheck/HxcCheck.csproj`, `tests/fixtures/hxccheck/Program.cs`
- Create: `tests/dotnet/run.sh`, `tests/dotnet/cases.hx.txt`
- Create: `src/hxc/codegen/dotnet/{IlBytes,MetaHeaps,MetaTables,PeWriter,ModuleBuilder,GenerateDotnet}.hx`
- Modify: `src/hxc/Compiler.hx` (generate dispatch, next to the JVM branch)
- Modify: `.github/workflows/ci.yml` (new job after `jvm`)

**Interfaces:**
- Produces:
  - `IlBytes`: `new()`, `length:Int`, `u8/u16/u32(v:Int)`, `i64(v:haxe.Int64)`, `f32/f64(v:Float)`,
    `bytes(b:Bytes)`, `compressedU32(v:Int)`, `compressedI32(v:Int)`, `align(n:Int)` (zero fill),
    `patchU32(pos:Int, v:Int)`, `getBytes():Bytes`.
  - `MetaHeaps`: `StringHeap.add(s:String):Int` (`""` → 0), `UserStringHeap.add(s:String):Int`,
    `BlobHeap.add(b:Bytes):Int` (empty → 0), `GuidHeap.add(g:Bytes):Int` (1-based); each has
    `bytes():Bytes` padded to 4 and `isLarge():Bool` (size ≥ 0x10000).
  - `MetaTables`: one `Array<Row>` per table written (Module, TypeRef, TypeDef, Field, MethodDef,
    Param, InterfaceImpl, MemberRef, CustomAttribute, StandAloneSig, TypeSpec, Assembly,
    AssemblyRef, GenericParam, MethodSpec), `CodedIndex` encoders, and
    `writeMetadata(h:MetaHeaps):{bytes:Bytes, mvidOffset:Int}` (root + all streams).
  - `typedef AssemblyIdentity = {name:String, version:Array<Int>, culture:String, publicKeyToken:Null<Bytes>}`
    in `ModuleBuilder.hx`.
  - `ModuleBuilder`: `new(name:String, isDll:Bool)`, `assemblyRef(id:AssemblyIdentity):Int` (row,
    deduped by name), `finish(entryPoint:Int):Bytes` (`0` for none).
  - `PeWriter.write(img:{metadata:Bytes, mvidOffset:Int, il:Bytes, entryPoint:Int, isDll:Bool}):Bytes`,
    and `PeWriter.IL_RVA = 0x2050`, the RVA where `il` starts (MethodDef RVAs are `IL_RVA + offset`).
  - `GenerateDotnet.generate(ctx:Context):Void`.
  - `run.sh` and `cases.hx.txt` as specified below; every later task adds cases.

- [ ] **Step 1: Write the checker tool**

`HxcCheck.csproj`: console app, `net10.0`, `PackageReference Microsoft.ILVerification 10.0.13`,
nullable enabled. `Program.cs` takes two commands:

- `verify <dll>`: ILVerify over method bodies **and** type definitions, as the `ilverify` CLI does by
  default, with `System.Private.CoreLib` as the system module. References resolve from the
  directory of `typeof(object).Assembly.Location` (the shared framework that runs the tool) and the
  DLL's own directory. Prints one line per error, `<Type>::<Method>: <code> <message>`, exits 1 on
  any error, prints nothing and exits 0 when clean.
- `dump <dll> <items>`: `<items>` is a comma-separated list; prints, in the order listed:
  `assembly` → `assembly <name> <a.b.c.d>`; `refs` → one `assemblyref <name> <a.b.c.d> <token hex or null>`
  per row in table order; `entrypoint` → `entrypoint <type>::<method>`; any other item is a type's
  full name (`ns.Name`, or `Name` with no namespace, including the arity suffix) and prints:

```
type <words> <fullname>[<T, U>] [extends <type>] [implements <type>, <type>]
  field <words> <type> <name>
  method <words> <ret> <name>[<S>](<type>, <type>)
```

Fields, then methods, each in table order. Type words, in this order and only when set: the
visibility (`public` or `private`), `interface`, `abstract`, `sealed`, `sequential`,
`beforefieldinit`. Method words: the access (`public`, `private`, `family`, `assembly`,
`famorassem`, `famandassem`, `privatescope`), then `static final virtual hidebysig newslot abstract
specialname rtspecialname`. Field words: the access, then `static initonly literal`. Types print
ILDasm style: `void bool char int8 uint8 int16 uint16 int32 uint32 int64 uint64 float32 float64
string object typedref`, `native int`, `native uint`; a type defined in the dumped assembly as its
full name; a referenced one as `[<assembly>]<full name>`; a nested type as `Outer/Inner`; generic
instances `X<a, b>`; `!0`, `!!0`; `T[]`, `T&`, `T*`. An item that matches nothing prints
`missing <item>`.

- [ ] **Step 2: Write `tests/dotnet/run.sh`**

`tests/dotnet/run.sh --compiler <hxc> [--std <dir>] [--case <name>]`. It builds `HxcCheck` once
(`dotnet build tests/fixtures/hxccheck -c Release -o tests/fixtures/hxccheck/bin/out`), then for
each case in `cases.hx.txt` (format: haxe-conformance's `--- name` / source / `===` / expected), in
a fresh temporary directory:

1. Writes the source to `P.hx`, or to `<pack>/<Mod>.hx` with `@module=pack.Mod`.
2. Compiles twice, with `HAXE_STD_PATH` set from `--std`:
   `<hxc> --cwd <dir> -cp . --main <module> --cs a/P -D dotnet <extra>` and the same with `b/P`.
   With `@lib` there is no `--main`; the module name is passed as a bare argument instead. `<extra>`
   is whatever follows `+` in the header.
3. If `a/P` holds a `.dll`: compares every file in `a/P` and `b/P` byte for byte (failure:
   `not deterministic: <file>`), runs `HxcCheck verify` (failure: its output), runs
   `dotnet a/P/<name>.dll` unless `@lib`, and runs `HxcCheck dump` when the header has
   `@dump=<items>`.
4. Builds the result from sections, each present only when non-empty: `[compile]` (the first
   compile's stdout+stderr), `[run]` (the program's stdout+stderr, then `[exit <n>]` when the exit
   code isn't 0), `[dump]`. Line endings become `\n`, the case directory becomes `$CASE`, trailing
   whitespace is trimmed. The result must equal the expected block.

It prints `ok <name>` or `FAIL <name>` with a diff, and exits 1 if any case failed.

- [ ] **Step 3: Write the Task 1 cases (they fail: nothing is written yet)**

```
--- empty-library @lib @dump=assembly
class P {}
===
[dump]
assembly P 1.0.0.0
--- dll-name-define @lib @dump=assembly + -D dll-name=HaxeServer
class P {}
===
[dump]
assembly HaxeServer 1.0.0.0
--- dll-name-with-dots @lib @dump=assembly + -D dll-name=My.App
class P {}
===
[dump]
assembly My.App 1.0.0.0
```

- [ ] **Step 4: Run them to see them fail**

Run: `tests/dotnet/run.sh --compiler bin/cpp/windows/x64/release/bin/hxc.exe --std C:/HaxeToolkit/haxe/std`
Expected: three `FAIL` lines (no `.dll` written).

- [ ] **Step 5: Implement the writers and the dispatch**

- Dispatch in `Compiler.hx` beside the JVM branch: `platform == Cs && ctx.defines.rawDefined("dotnet")`
  logs `Generating dotnet: <file>` and runs `GenerateDotnet.generate(ctx)` under the timer
  `["generate", "dotnet"]`.
- Heaps follow ECMA-335 II.24.2.2-4: `#Strings` starts with `\0`; `#US` entries are UTF-16LE with a
  compressed length and a final byte that is 1 when any char is ≥ 0x7F or in 0x01-0x08, 0x0E-0x1F,
  0x27, 0x2D; `#Blob` entries have a compressed length; all deduped, in first-added order.
- `#~` per II.24.2.6: version 2.0, `HeapSizes` from `isLarge()`, `Valid` mask from non-empty tables,
  `Sorted` mask `0x16003301FA00`, row counts, then rows with 2- or 4-byte indices chosen per table
  and coded index (II.24.2.6 coded index tables). Sort InterfaceImpl, CustomAttribute,
  GenericParam (owner, then number) and GenericParamConstraint by their key before writing.
- Metadata root per II.24.2.1: signature `0x424A5342`, version 1.1, version string `v4.0.30319`
  padded to 12 bytes, streams in the order `#~`, `#Strings`, `#US`, `#GUID`, `#Blob`.
- `ModuleBuilder.finish`: Module row (name `<name>.dll`, Mvid = GUID index 1, a zero GUID added
  first), TypeDef row 1 `<Module>` (no namespace, flags 0, no base), Assembly row (HashAlgId
  `0x8004`, version 1.0.0.0, flags 0, no public key, culture `""`).
- `PeWriter`, PE32 per II.25 with these values: file alignment 0x200, section alignment 0x2000,
  image base 0x400000 for an exe and 0x10000000 for a DLL, machine 0x14C, characteristics `0x0102`
  (exe) / `0x2102` (DLL), linker 48.0, OS and subsystem version 4.0, subsystem 3, DLL characteristics
  `0x8540`, stack reserve/commit 0x100000/0x1000, heap 0x100000/0x1000. Sections `.text` (RVA 0x2000)
  and `.reloc`. `.text` layout: IAT (8 bytes) at 0x2000, CLI header (72 bytes) at 0x2008, IL at
  `IL_RVA` (0x2050), metadata (4-aligned), the import directory, import lookup table, hint/name
  `_CorExeMain` or `_CorDllMain`, `mscoree.dll`, then the entry stub `FF 25 <IAT VA>` placed so its
  operand is 4-aligned. `.reloc` holds one HIGHLOW fixup for that operand. CLI header: runtime 2.5,
  flags `COMIMAGE_FLAGS_ILONLY` (1), the entry point token. Data directories: import, base
  relocation, IAT, CLI header.
- Determinism, as Roslyn's deterministic mode does it: write the image with the MVID and
  `TimeDateStamp` zeroed, SHA-256 the whole image (`haxe.crypto.Sha256`), MVID = hash bytes 0-15 with
  `b[7] = (b[7] & 0x0F) | 0x40` and `b[8] = (b[8] & 0x3F) | 0x80`, timestamp = hash bytes 16-19
  little-endian with the top bit set; patch both in.
- `GenerateDotnet.generate`: name from `dll_name` or the last segment of `ctx.file`; writes
  `<name>.dll`. With `ctx.main != null` it also writes `<name>.runtimeconfig.json`, exactly this,
  `\n` line endings, final newline:

```json
{
  "runtimeOptions": {
    "tfm": "net10.0",
    "framework": {
      "name": "Microsoft.NETCore.App",
      "version": "10.0.0"
    }
  }
}
```

- [ ] **Step 6: Add the CI job**

In `ci.yml`, a job `dotnet` (name `.NET`, `needs: build`, `runs-on: windows-2022`, 30 minutes) with
the `jvm` job's checkout and `setup-tests` steps, `actions/setup-dotnet@v4` with `dotnet-version:
"10.0.x"`, and a bash step:
`tests/dotnet/run.sh --compiler "${{ steps.t.outputs.hxc }}" --std "$HAXE_STD_PATH"`.

- [ ] **Step 7: Build hxc and run the cases**

Run: the build command from the project memory note (`AEDIFEX_ROOT=D:/_github/hxc-toolchain/aedifex/
HAXE_STD_PATH=C:/HaxeToolkit/haxe/std HXCPP_COMPILE_CACHE=D:/_github/hxc-toolchain/hxcpp-cache
haxelib run aedifex build cpp .`), then the Step 4 command.
Expected: `ok empty-library`, `ok dll-name-define`, `ok dll-name-with-dots`, exit 0.

- [ ] **Step 8: Run hxc's own families**

Run: `neko run.n run --compiler <hxc> --std C:/HaxeToolkit/haxe/std --cases D:/_github/hxc/tests/cases --expected D:/_github/hxc/tests/expected`
in `D:/_github/haxe-conformance`.
Expected: every family passes, `cs-target` included (no `-D dotnet` there, so nothing changes).

- [ ] **Step 9: Commit**

```bash
git add src/hxc/codegen/dotnet src/hxc/Compiler.hx tests/fixtures/hxccheck tests/dotnet .github/workflows/ci.yml
git commit -m "Write an empty .NET assembly for --cs with -D dotnet"
```

---

### Task 2: The first program: statics, extern calls, the entry point, and the stub rule

**Files:**
- Create: `src/hxc/codegen/dotnet/{SigWriter,IlCode,DotnetNames,DotnetTypes,ExternMembers,TclassToIl,TexprToIl}.hx`
- Modify: `src/hxc/codegen/dotnet/{ModuleBuilder,GenerateDotnet,NetLibrary}.hx`
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: Task 1's `ModuleBuilder`, `IlBytes`, `PeWriter.IL_RVA`, `AssemblyIdentity`.
- Produces:
  - `NetLibrary.identity():AssemblyIdentity` (from the Assembly row; the token is the last 8 bytes,
    reversed, of the SHA-1 of the public key, `null` without one) and
    `NetLibrary.definesType(path:IlPath):Bool`.
  - `SigWriter`: `new(typeToken:(path:IlPath, valueType:Bool) -> Int)` where the callback returns a
    TypeDefOrRef coded index; `type(b:IlBytes, t:IlSigNorm)`, `field(t:IlSigNorm):Bytes`,
    `method(hasThis:Bool, ret:IlSigNorm, args:Array<IlSigNorm>, genericCount:Int):Bytes`,
    `locals(ts:Array<IlSigNorm>):Bytes`, `typeSpec(t:IlSigNorm):Bytes`,
    `methodSpec(args:Array<IlSigNorm>):Bytes`.
  - `IlCode`: `newLabel():Label`, `mark(l:Label)`, `op(code:Int, pops:Int, pushes:Int)`,
    `opI32(code, v, pops, pushes)`, `opI64`, `opR8`, `opToken(code, token:Int, pops, pushes)`,
    `branch(code, l:Label)`, `ldarg/starg/ldloc/stloc/ldloca(i:Int)` and `ldcI4(v:Int)` choosing the
    short forms, `addLocal(t:IlSigNorm):Int`, `beginTry()`, `beginCatch(classToken:Int)`,
    `endTry()`, `maxStack:Int`, `body(localsToken:Int):Bytes`. Opcode values as `IlOps` inline
    constants; two-byte opcodes are `0xFE00 | b`.
  - `ModuleBuilder` gains: `typeDef(...)`, `field(...)`, `method(...)` (rows in declaration order,
    token returned), `typeToken(path:IlPath, valueType:Bool):Int`,
    `memberRef(parent:Int, name:String, sig:Bytes):Int`, `typeSpec(sig:Bytes):Int`,
    `userString(s:String):Int`, `standAloneSig(sig:Bytes):Int`, all deduped, and
    `externScope:(IlPath) -> AssemblyIdentity` set by the emitter.
  - `DotnetNames.typePath(mt:ModuleType):IlPath`, `DotnetNames.fieldName(c:TClass, name:String):String`.
  - `class Unsupported { what:String; pos:Position; }` (thrown) and `DotnetTypes`:
    `new(ctx:Context, mb:ModuleBuilder)`, `toSig(t:Type):IlSigNorm`, `externPath(c:TClass):Null<IlPath>`.
  - `ExternMembers`: `method(c:TClass, cf:TClassField):{parent:IlSigNorm, name:String, sig:IlSigNorm, isStatic:Bool}`,
    `field(c:TClass, cf:TClassField):ExternField` with
    `enum ExternField { XField(sig:IlSigNorm); XConstant(c:IlConstant); XProperty(sig:IlSigNorm, getter:Null<String>, setter:Null<String>); }`.
  - `TclassToIl.declare(g:DotnetCtx, c:TClass):Void`, `TclassToIl.emit(g:DotnetCtx, c:TClass):Void`.
  - `TexprToIl`: `new(g:DotnetCtx, code:IlCode, ret:IlSigNorm)`, `texpr(ret:Ret, e:TExpr):Void` with
    `enum Ret { RValue(t:Null<IlSigNorm>); RVoid; RReturn; }` (the JVM backend's shape).
  - `DotnetCtx` (in `GenerateDotnet.hx`): the context, module builder, `DotnetTypes`, method/field
    tokens keyed by `TClassField` identity, the skipped-type and stub lists.

- [ ] **Step 1: Write the Task 2 cases**

```
--- hello
class P {
	static function main() {
		Sys.println("Hello, world");
	}
}
===
[run]
Hello, world
--- println-boxes-values
class P {
	static function main() {
		Sys.println(42);
		Sys.println(true);
	}
}
===
[run]
42
True
--- static-calls-and-vars
class P {
	static var greeting = "hi";
	static var n:Int;
	static function add(a:Int, b:Int):Int {
		return a + b;
	}
	static function main() {
		n = add(2, 3);
		Sys.println(greeting);
		Sys.println(n);
	}
}
===
[run]
hi
5
--- extern-const
class P {
	static function main() {
		Sys.println(cs.system.Int32.MaxValue);
		Sys.println(cs.system.Math.Max(3, 9));
	}
}
===
[run]
2147483647
9
--- entry-point-in-main-class @dump=P,entrypoint
class P {
	static function main() {}
}
===
[dump]
type public beforefieldinit P extends [mscorlib]System.Object
  method public hidebysig specialname rtspecialname void .ctor()
  method public static hidebysig void main()
  method public static hidebysig void Main()
entrypoint P::Main
--- entry-point-class-for-main @module=Main @dump=Main,EntryPoint__Main,entrypoint
class Main {
	static function main() {}
}
===
[dump]
type public beforefieldinit Main extends [mscorlib]System.Object
  method public hidebysig specialname rtspecialname void .ctor()
  method public static hidebysig void main()
type public beforefieldinit EntryPoint__Main extends [mscorlib]System.Object
  method public hidebysig specialname rtspecialname void .ctor()
  method public static hidebysig void Main()
entrypoint EntryPoint__Main::Main
--- local-function-is-an-error
class P {
	static function main() {
		var f = function() {};
		f();
	}
}
===
[compile]
P.hx:3: characters 11-24 : dotnet: local functions are not supported yet
```

- [ ] **Step 2: Run them to see them fail**

Run: `tests/dotnet/run.sh --compiler <hxc> --std C:/HaxeToolkit/haxe/std`
Expected: the seven new cases FAIL; Task 1's still pass.

- [ ] **Step 3: Implement signatures, IL bodies and extern references**

- `SigWriter` encodes `IlSigNorm` per II.23.2: element types, `CLASS`/`VALUETYPE` + coded index,
  `GENERICINST`, `VAR`/`MVAR`, `SZARRAY`, `BYREF`, `PTR`; method signatures with `HASTHIS` (0x20) and
  `GENERIC` (0x10) plus the generic count; `LOCAL_SIG` (0x07).
- `IlCode` tracks stack depth from each op's pops/pushes, keeps the maximum, and records the depth
  at each label. After `br`, `leave`, `ret`, `throw` and `rethrow` the depth is unknown until the
  next `mark`, which takes the label's recorded depth. Any mismatch throws an internal error naming
  the method. Branches are always the long forms in this milestone. `body` writes a tiny header
  when code < 64 bytes, max stack ≤ 8, no locals and no clauses; otherwise a fat header (flags
  `0x3013` with InitLocals, `0x301B` with clauses), 4-byte aligned, and a fat EH section (24 bytes
  per clause).
- Extern types: `DotnetTypes.externPath` takes the path from `ctx.netPathMap`, then from
  `@:native("A.B.C")`, else throws `Unsupported`. `externScope` picks the first library in
  `ctx.netLibs` order whose `definesType` is true, and adds its `identity()` as an AssemblyRef. An
  extern Haxe type with no .NET path is dropped from `implements` lists.
- `ExternMembers.method`: on `c`, then up its supertypes, among the `IlMethod`s with the field's name
  (`.ctor` for `new`) and arity, the one whose parameter `IlSigNorm`s equal `toSig` of the
  field's argument types by `IlPaths.sigEq`; the MemberRef uses that `IlMethod.msig` unchanged
  (open `!0` form, parent the TypeSpec of the instantiation when the owner is generic). The typer's
  chosen overload (`cf`) decides; nothing is re-resolved. `ExternMembers.field`: a field with an
  `fconstant` is `XConstant`, inlined as its `ldc`; a property gives its accessor names.
- Type mapping in `toSig`: `Int` → `LInt32`, `Float` → `LFloat64`, `Bool` → `LBool`, `String` →
  `LString`, `Void` → `LVoid`, `Dynamic`/`Any`/monomorphs/anonymous structures → `LObject`, the
  `cs.types.*` and `cs.StdTypes` core types to their element types, `cs.NativeArray<T>` →
  `LVector`, `cs.Ref<T>`/`cs.Out<T>` → `LManagedPointer`, an extern `@:struct` class or a .NET enum →
  `LValueType`, abstracts → their underlying type, class type parameters → `LTypeParam`, method type
  parameters → `LMethodTypeParam`.

- [ ] **Step 4: Implement names, statics and the entry point**

- `DotnetNames.typePath` follows gencs `change_ns_params` (line 785): a top-level type has no
  namespace; with `-D no-root`, top-level non-extern types, `Std` and `Math` go to `haxe.root`;
  `@:native` replaces the path; a generic type's name gets `` `N ``. `fieldName` renames a member
  named like its class to `Name_Name`, repeated while that collides (`change_class_field`, line 806).
- Every member is `public` (gencs line 2324). Static methods are `public static hidebysig`.
- Member order: instance fields then static fields, then `.ctor`, instance methods, static methods,
  each in declaration order; the entry point `Main()` and `.cctor` last.
- A class without a `new` gets C#'s implicit constructor: `public hidebysig specialname
  rtspecialname .ctor()` that calls the base type's parameterless `.ctor` (`family` when the class
  is abstract).
- Static var initializers and the class's `__init__` go into one `.cctor` (`private static
  hidebysig specialname rtspecialname`), the way gencs writes `static Name() { ... }` (line 2707);
  take the order of the two from gencommon's static-initializer handling in Haxe 4.3.7. A class with
  a `.cctor` has no `beforefieldinit`; every other class has it, as C# marks a class without a
  static constructor.
- Entry point, as gencs does (line 2645): if the main class is named `Main`, a separate class
  `EntryPoint__Main` (same namespace as `Main`) holds `public static void Main()`; otherwise the main
  class itself gets that method, after its own fields. `Main()` calls `cs.Boot.init()` when `cs.Boot`
  is in `ctx.types`, then evaluates `ctx.main`. Its token goes into the CLI header.

- [ ] **Step 5: Implement the stub rule and the expression subset**

The rule, in `GenerateDotnet` and `TclassToIl`:

- A type is *standard library* when its position's file is under one of `ctx.stdPath`.
- `Unsupported` thrown while declaring a type: for a standard-library type, the type is left out and
  recorded as `skipped <hx path>: <what>`; for user code, `ctx.addDiagnostic("dotnet: <what> is
  not supported yet", pos)`.
- `Unsupported` thrown while lowering a method body: for a standard-library method, the body becomes
  `ldstr "hxc dotnet: <Class>.<method> uses <what>, which is not supported yet"`, `newobj
  System.NotSupportedException::.ctor(string)`, `throw`, recorded as `stubbed <Class>.<method>:
  <what>`; for user code, the diagnostic above at the expression's position.
- A reference to a left-out type throws `Unsupported("<hx path> (left out: <reason>)")`.
- Inline C# until milestone 4: `@:functionCode` on a method throws `Unsupported("@:functionCode")`
  (so a standard-library method with it is stubbed); `@:classCode` on a standard-library type is
  ignored and recorded as `ignored @:classCode in <hx path>` (code that calls the members it
  defines is `untyped`, so it stubs itself); on a user type, both are the usual diagnostic.
- When any diagnostic was added, `generate` writes no files.
- `-D dotnet-stub-report` prints every record, sorted, one `ctx.info` each, at `Position.nullPos`.
  Without it nothing is printed. Messages never contain file paths.

`TexprToIl` in this task: constants (`Int`, `Float`, `String`, `Bool`, `null`), locals and arguments,
`TVar`, assignment to locals and static fields, `TBlock`, `TReturn`, `TParenthesis`, `TMeta`, static
calls to Haxe methods, extern static and instance calls, extern static and instance property reads
and writes, extern constructors (`TNew`), and the coercion between a value's type and the slot it
goes into: value type → `LObject` boxes, `LObject` → value type `unbox.any`, `LInt32` → `LFloat64`
`conv.r8`, identical types nothing. Anything else throws `Unsupported` with `what` naming the
construct; `TFunction` is `"local functions"`. `cs.Boot.init`, `cs.Lib.applyCultureChanges` and
what they run (`cs.Lib`'s `.cctor`) must lower with this subset; if any is stubbed, `hello` fails.

- [ ] **Step 6: Run the cases**

Run: the Task 1 build command, then `tests/dotnet/run.sh --compiler <hxc> --std C:/HaxeToolkit/haxe/std`
Expected: all ten cases `ok`.

- [ ] **Step 7: Commit**

```bash
git add src/hxc/codegen/dotnet tests/dotnet
git commit -m "Emit static methods, extern calls and the entry point for -D dotnet"
```

---

### Task 3: Operators, control flow and strings

**Files:**
- Modify: `src/hxc/codegen/dotnet/TexprToIl.hx`
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: Task 2's `TexprToIl`, `IlCode`, `ExternMembers`.
- Produces: nothing new for later tasks beyond the wider `texpr`.

- [ ] **Step 1: Write the cases**

Inputs come from static vars so the analyzer can't fold them.

```
--- int-arithmetic
class P {
	static var max = 2147483647;
	static var m7 = -7;
	static var m1 = -1;
	static var m16 = -16;
	static var one = 1;
	static var six = 6;
	static var seven = 7;
	static function main() {
		Sys.println(max + one);
		Sys.println(m7 % 3);
		Sys.println(m1 >>> 28);
		Sys.println(m16 >> 2);
		Sys.println(one << 33);
		Sys.println(((six & 3) | 8) ^ one);
		Sys.println(~six);
		Sys.println(Std.int(seven / 2));
		Sys.println(Std.int(m7 / 2));
	}
}
===
[run]
-2147483648
-1
15
-4
2
11
-7
3
-3
--- float-compare-nan
class P {
	static var nan = Math.NaN;
	static var one = 1.0;
	static function main() {
		Sys.println(nan < one);
		Sys.println(nan >= one);
		Sys.println(!(nan < one));
		Sys.println(nan == nan);
		Sys.println(nan != nan);
		Sys.println(one <= 1);
	}
}
===
[run]
False
False
True
False
True
True
--- control-flow
class P {
	static var n = 5;
	static function main() {
		var i = 0;
		var sum = 0;
		while (true) {
			i++;
			if (i > n * 2) break;
			if (i % 2 == 0) continue;
			sum += i;
		}
		Sys.println(sum);
		var j = 10;
		do j -= 3 while (j > 0);
		Sys.println(j);
		Sys.println(n > 3 ? "big" : "small");
		var k = 0;
		for (x in 0...n) k += x;
		Sys.println(k);
	}
}
===
[run]
25
-2
big
10
--- switch
class P {
	static function name(i:Int):String {
		return switch (i) {
			case 1: "one";
			case 2 | 3: "few";
			default: "many";
		}
	}
	static function kind(s:String):Int {
		switch (s) {
			case "a": return 1;
			case "b": return 2;
		}
		return 0;
	}
	static function main() {
		Sys.println(name(1) + name(3) + name(9));
		Sys.println(kind("b") + kind("z"));
	}
}
===
[run]
onefewmany
2
--- strings
class P {
	static var s = "héllo";
	static var t = "h\u00e9llo";
	static var i = 42;
	static var b = true;
	static var m = -3;
	static var nothing:String = null;
	static var emoji = "😀";
	static function main() {
		Sys.println(s == t);
		Sys.println(s.length);
		Sys.println(emoji.length);
		Sys.println("n=" + i + "," + b + "," + m + "," + nothing);
		Sys.println(s.toUpperCase() == "HÉLLO");
	}
}
===
[run]
True
5
2
n=42,true,-3,null
True
--- many-locals-and-deep-stack
import haxe.macro.Expr;
class P {
	static var seed = 0;
	static macro function locals(n:Int):Expr {
		var block = [];
		var sum = macro 0;
		for (i in 0...n) {
			var id = "v" + i;
			block.push(macro var $id = P.seed + $v{i});
			sum = macro $sum + $i{id};
		}
		block.push(sum);
		return macro $b{block};
	}
	static macro function nested(n:Int):Expr {
		var e = macro P.seed;
		for (i in 0...n) e = macro P.seed + $v{n - i} + ($e);
		return e;
	}
	@:analyzer(ignore) static function main() {
		Sys.println(locals(300));
		Sys.println(nested(20));
	}
}
===
[run]
44850
210
```

- [ ] **Step 2: Run them to see them fail**

Run: `tests/dotnet/run.sh --compiler <hxc> --std C:/HaxeToolkit/haxe/std`
Expected: the six new cases FAIL with `dotnet: ... is not supported yet` diagnostics.

- [ ] **Step 3: Implement the operators**

- Arithmetic on `Int` and `Float` with the usual promotion (an `Int` operand of a `Float` operation
  gets `conv.r8`); `/` always divides as `Float`; `%` is `rem`; `>>>` is `shr.un`; shift counts are
  masked with `ldc.i4.s 31; and` before `shl`/`shr`/`shr.un`; `~` is `not`; unary `-` is `neg`.
- Comparisons produce a `bool` (`ceq`, `cgt`, `clt`, inverted with `ldc.i4.0; ceq`); for `Float`,
  `>=` and `<=` use `clt.un`/`cgt.un` before inverting, so NaN makes them false. Conditions branch
  with `brtrue`/`brfalse` on that value. `&&`/`||` short-circuit. `==`/`!=` on two `String`s call
  `[mscorlib]System.String::op_Equality(string, string)`; on other reference types, `ceq`.
- `++`/`--` (pre and post) and compound assignment on locals and static fields, leaving the right
  value when the result is used.
- `Std.int(x)` is `conv.i4` (gencs line 446).
- String `+`, as gencs lowers it (lines 3349 and 531, `Runtime.concat` and `Runtime.toString`):
  `System.String::Concat(string, string)` over operands converted so that a `null` string prints
  `null`, `Int` and `Float` print through `box` + `callvirt Object::ToString()`, `Bool` prints
  `true`/`false`, and a class instance prints its `ToString()` (`null` → `null`). A `Dynamic`
  operand throws `Unsupported("Dynamic in string concatenation")` until milestone 3.
- `String` members, as gencs maps them (line 448): `length` → `get_Length`, `toLowerCase` →
  `ToLowerInvariant`, `toUpperCase` → `ToUpperInvariant`, `toString()` → the string itself,
  `new String(s)` → `s`, `fromCharCode` and `charAt`, `charCodeAt`, `indexOf`, `lastIndexOf`,
  `split`, `substring`, `substr` → static calls to `haxe.lang.StringExt` with the receiver first;
  other members (the private externs such as `StartsWith`) → the `System.String` member of the same
  name.

- [ ] **Step 4: Implement control flow**

`TIf` (as a statement and as a value), `TWhile` (both forms), `TBreak`, `TContinue`, `TSwitch` on
`Int` and `String` (a chain of comparisons with the default last; `switch` as a value), `TUnop`
`!`. Values left by both branches of a value `if`/`switch` meet at a label with the same depth.

- [ ] **Step 5: Run the cases**

Run: the Task 1 build command, then `tests/dotnet/run.sh --compiler <hxc> --std C:/HaxeToolkit/haxe/std`
Expected: every case `ok`.

- [ ] **Step 6: Commit**

```bash
git add src/hxc/codegen/dotnet/TexprToIl.hx tests/dotnet/cases.hx.txt
git commit -m "Lower operators, control flow and string concatenation for -D dotnet"
```

---

### Task 4: Classes, interfaces and CLR names

**Files:**
- Modify: `src/hxc/codegen/dotnet/{TclassToIl,TexprToIl,DotnetNames}.hx`
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: Task 2's `TclassToIl.declare/emit`, `DotnetCtx` token maps, `ExternMembers`.
- Produces: `DotnetCtx` method and field tokens for instance members, which Task 5 instantiates over
  generic owners.

- [ ] **Step 1: Write the cases**

```
--- classes-and-inheritance
class Animal {
	public var name:String;
	public function new(name:String) {
		this.name = name;
	}
	public function speak():String {
		return name + " makes a sound";
	}
}
class Dog extends Animal {
	public function new() {
		super("Rex");
	}
	override public function speak():String {
		return super.speak() + ": woof";
	}
}
interface Greeter {
	function greet():String;
}
class Hello implements Greeter {
	public function new() {}
	public function greet():String {
		return "hello";
	}
	public function toString():String {
		return "Hello!";
	}
}
class P {
	static function main() {
		var a:Animal = new Dog();
		Sys.println(a.speak());
		var g:Greeter = new Hello();
		Sys.println(g.greet());
		Sys.println(a.name);
		Sys.println("" + new Hello());
	}
}
===
[run]
Rex makes a sound: woof
hello
Rex
Hello!
--- constructors-and-field-inits
class Base {
	public var items = 3;
	public function new() {}
}
class Counter extends Base {
	public var count:Int = 10;
	public function new() {
		super();
		count += items;
	}
}
class NoCtor {
	public static function hi() return "hi";
}
class Child extends NoCtor {
	public function new() {}
}
class P {
	static function main() {
		Sys.println(new Counter().count);
		Sys.println(new Child() != null);
		Sys.println(NoCtor.hi());
	}
}
===
[run]
13
True
hi
--- static-init-order
class A {
	public static var x = B.y + 1;
}
class B {
	public static var y = 41;
}
class P {
	static function main() {
		Sys.println(A.x);
	}
}
===
[run]
42
--- extends-native-exception @dump=MyError
class MyError extends cs.system.Exception {
	public var code:Int;
	public function new(code:Int) {
		super("my error");
		this.code = code;
	}
}
class P {
	static function main() {
		var e = new MyError(7);
		Sys.println(e.Message + " " + e.code);
	}
}
===
[run]
my error 7
[dump]
type public beforefieldinit MyError extends [mscorlib]System.Exception
  field public int32 code
  method public hidebysig specialname rtspecialname void .ctor(int32)
--- clr-names @lib @module=pack.Thing @dump=pack.IRun,pack.Thing,pack.Sealed
package pack;
interface IRun {
	function run(x:Int):Void;
}
class Thing implements IRun {
	public var Thing:Int;
	public var other:String;
	public function new() {}
	public function run(x:Int):Void {}
	public final function stop():Void {}
	public static function make():Thing {
		return new Thing();
	}
}
final class Sealed {
	public function new() {}
	public function go():Void {}
}
===
[dump]
type public interface abstract pack.IRun
  method public virtual hidebysig newslot abstract void run(int32)
type public beforefieldinit pack.Thing extends [mscorlib]System.Object implements pack.IRun
  field public int32 Thing_Thing
  field public string other
  method public hidebysig specialname rtspecialname void .ctor()
  method public virtual hidebysig newslot void run(int32)
  method public hidebysig void stop()
  method public static hidebysig pack.Thing make()
type public sealed beforefieldinit pack.Sealed extends [mscorlib]System.Object
  method public hidebysig specialname rtspecialname void .ctor()
  method public hidebysig void go()
```

- [ ] **Step 2: Run them to see them fail**

Run: `tests/dotnet/run.sh --compiler <hxc> --std C:/HaxeToolkit/haxe/std`
Expected: the five new cases FAIL.

- [ ] **Step 3: Implement declarations**

Modifiers, as gencs writes them (lines 2296-2330) and C# compiles them:

- Classes: `public`; `sealed` when final; `abstract` when abstract; `beforefieldinit` per Task 2.
  Interfaces: `public interface abstract`, methods `public virtual hidebysig newslot abstract`; an
  interface var throws `Unsupported("interface variables")`. `@:struct` classes: `public sealed
  sequential`, extending `[mscorlib]System.ValueType`.
- Instance methods: `virtual newslot` unless the field or class is final, the method is inline or
  the class is an interface, in which case plain `hidebysig`; overrides (`override`, or
  `Equals(Dynamic):Bool` and `GetHashCode()`) are `virtual` without `newslot`; a non-virtual method
  that implements an interface method is `virtual final newslot`. All carry `hidebysig`.
- Fields only for physical vars (`TypeFunctions.isPhysicalField`), `public`, `static` for statics.
- Member order as Task 2 pins it.
- `@:overload` methods become one MethodDef each, keyed by their `TClassField`.
- A class with a `toString():String` gets `public virtual hidebysig string ToString()` (an override,
  no `newslot`) that returns `this.toString()` (gencs line 2518).
- A constructor that doesn't call `super(...)` calls the base type's parameterless `.ctor` first; if
  the base is an extern without one, `Unsupported("a base class without a parameterless constructor")`.

- [ ] **Step 4: Implement instance expressions**

`this`, `super(...)` and `super.m()` (`call`, not `callvirt`), instance field reads and writes
(`ldfld`/`stfld`) including `++`/`--` and compound assignment on them, `TNew` on Haxe classes,
`callvirt` for instance methods (`call` for non-virtual ones on a non-null receiver is allowed but
not required), interface calls, extern instance fields of a Haxe-extended native type, `ceq`
reference equality and `null` checks on class instances, and `TCast` to a class type: `castclass`
for a checked cast or a downcast, nothing for an upcast. A cast to an instantiation of a generic
Haxe class is never `castclass`; Task 5 handles it.

- [ ] **Step 5: Run the cases**

Run: the Task 1 build command, then `tests/dotnet/run.sh --compiler <hxc> --std C:/HaxeToolkit/haxe/std`
Expected: every case `ok`.

- [ ] **Step 6: Commit**

```bash
git add src/hxc/codegen/dotnet tests/dotnet/cases.hx.txt
git commit -m "Emit classes, interfaces and constructors with gencs's CLR names"
```

---

### Task 5: Generics and arrays

**Files:**
- Modify: `src/hxc/codegen/dotnet/{TclassToIl,TexprToIl,DotnetTypes,ModuleBuilder}.hx`
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: Task 4's declarations and token maps; `SigWriter.typeSpec/methodSpec`.
- Produces: `ModuleBuilder.genericParam(owner:Int, number:Int, name:String)`,
  `ModuleBuilder.methodSpec(method:Int, sig:Bytes):Int`, and `DotnetTypes.toSig` covering
  `Array<T>`, `Null<T>`, function types and `Class<T>`.

- [ ] **Step 1: Write the cases**

```
--- arrays
class P {
	static function main() {
		var a = [3, 1, 2];
		a.push(10);
		a[0] = a[1] + a[3];
		var sum = 0;
		for (x in a) sum += x;
		Sys.println(a.length);
		Sys.println(sum);
		var names = ["x", "y"];
		Sys.println(names[1]);
		var n = new cs.NativeArray<Int>(3);
		n[2] = 7;
		Sys.println(n.Length + n[2]);
	}
}
===
[run]
4
24
y
10
--- generic-classes-and-methods
class Box<T> {
	public var value:T;
	public function new(v:T) {
		value = v;
	}
	public function get():T {
		return value;
	}
	public static function of<U>(v:U):Box<U> {
		return new Box(v);
	}
}
class Pair<A, B> {
	public var a:A;
	public var b:B;
	public function new(a:A, b:B) {
		this.a = a;
		this.b = b;
	}
	public function swap():Pair<B, A> {
		return new Pair(b, a);
	}
}
class P {
	static function main() {
		var b = Box.of(41);
		Sys.println(b.get() + 1);
		var s = new Box("str");
		Sys.println(s.value);
		var p = new Pair(1, "one").swap();
		Sys.println(p.a + p.b);
	}
}
===
[run]
42
str
one1
--- generic-names @lib @module=pack.Box @dump=pack.Box`1
package pack;
class Box<T> {
	public var value:T;
	public function new(v:T) {
		value = v;
	}
	public function pick<S>(s:S):T {
		return value;
	}
}
===
[dump]
type public beforefieldinit pack.Box`1<T> extends [mscorlib]System.Object
  field public !0 value
  method public hidebysig specialname rtspecialname void .ctor(!0)
  method public virtual hidebysig newslot !0 pick<S>(!!0)
--- type-mapping @lib @module=pack.Sig @dump=pack.Sig
package pack;
class Sig {
	public static function f(a:Null<Int>, b:Dynamic, c:Array<String>, d:cs.NativeArray<Float>, e:Null<String>, g:Int->Void, h:{x:Int}, i:Class<Sig>):Void {}
}
===
[dump]
type public beforefieldinit pack.Sig extends [mscorlib]System.Object
  method public hidebysig specialname rtspecialname void .ctor()
  method public static hidebysig void f(haxe.lang.Null`1<int32>, object, Array`1<string>, float64[], string, haxe.lang.Function, object, [mscorlib]System.Type)
--- generic-instantiation-cast-is-an-error
class P {
	static function main() {
		var a:Array<Dynamic> = [1, 2, 3];
		var b:Array<Int> = cast a;
		var c:Array<Dynamic> = b;
		Sys.println(b.length + c.length);
	}
}
===
[compile]
P.hx:4: characters 22-28 : dotnet: a cast between instantiations of Array is not supported yet
P.hx:5: characters 26-27 : dotnet: a cast between instantiations of Array is not supported yet
```

- [ ] **Step 2: Run them to see them fail**

Run: `tests/dotnet/run.sh --compiler <hxc> --std C:/HaxeToolkit/haxe/std`
Expected: the five new cases FAIL.

- [ ] **Step 3: Implement generic declarations and references**

- Class type parameters → GenericParam rows on the TypeDef (named as in Haxe), method type
  parameters → GenericParam rows on the MethodDef. No constraints in this milestone.
- Signatures inside a generic class use `!n`; a member of an instantiated owner is a MemberRef whose
  parent is the instance's TypeSpec and whose signature is the declaration's open signature; a
  generic method call adds a MethodSpec.
- A static member of a generic Haxe class is reached through the instantiation with `object` for
  each class type parameter, as gencs writes it.
- A generic class with a `.cctor` gets a `static bool __hx_init_called` field and the guard gencs
  writes (line 2716), since the CLR runs a `.cctor` per instantiation.
- Coercions between a type parameter and `object`: `box !n` / `unbox.any !n`.
- A cast or coercion into an instantiation of a generic Haxe class from `Dynamic`, a type parameter
  or another instantiation of that class (`Array<Dynamic>` → `Array<Int>` and back) throws
  `Unsupported("a cast between instantiations of <hx path>")`. It is never `castclass`, which would
  throw `InvalidCastException` where hxcs converts. Milestone 3 lowers it as the spec's *Casts
  between generic instantiations* says (Haxe issue 8314: `Array` shares storage instead of copying).
- `toSig`: `Null<T>` → `haxe.lang.Null`1<T>` (the standard library's `cs.internal.Null` struct) when
  `T` maps to a value type, `T` otherwise; function types → `haxe.lang.Function`; `Class<T>` and
  `Enum<T>` → `[mscorlib]System.Type`; `Array<T>` → the `Array`1` the standard library declares.

- [ ] **Step 4: Implement arrays**

- `cs.NativeArray`: `new NativeArray<T>(n)` → `newarr`, element read/write → `ldelem`/`stelem` with
  the element type token, `Length` → `ldlen; conv.i4`.
- `Array<T>` is the standard library's class, compiled like user code; `a[i]` and `a[i] = v` call its
  `__get`/`__set`; an array literal `[e1, e2]` is `newarr` filled with `stelem`, then
  `newobj Array`1<T>::.ctor(!0[])`.

- [ ] **Step 5: Run the cases**

Run: the Task 1 build command, then `tests/dotnet/run.sh --compiler <hxc> --std C:/HaxeToolkit/haxe/std`
Expected: every case `ok`.

- [ ] **Step 6: Commit**

```bash
git add src/hxc/codegen/dotnet tests/dotnet/cases.hx.txt
git commit -m "Emit generic classes and methods, native arrays and Array for -D dotnet"
```

---

### Task 6: Exceptions

**Files:**
- Modify: `src/hxc/codegen/dotnet/{TexprToIl,IlCode}.hx`
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: Task 2's `IlCode.beginTry/beginCatch/endTry`, Task 4's classes.
- Produces: nothing new.

- [ ] **Step 1: Write the case**

```
--- exceptions
class MyError extends cs.system.Exception {
	public var code:Int;
	public function new(code:Int) {
		super("my error");
		this.code = code;
	}
}
class P {
	static function fail(n:Int):Int {
		if (n > 2) throw new MyError(n);
		return n;
	}
	static function attempt(n:Int):String {
		try {
			return "ok " + fail(n);
		} catch (e:MyError) {
			return "caught " + e.code + " " + e.Message;
		} catch (e:cs.system.Exception) {
			return "other";
		}
	}
	static function main() {
		Sys.println(attempt(1));
		Sys.println(attempt(5));
		var count = 0;
		for (i in 0...5) {
			try {
				if (i == 1) continue;
				if (i == 3) break;
				count += 10;
			} catch (e:cs.system.Exception) {}
		}
		Sys.println(count);
		var v = try fail(9) catch (e:MyError) -e.code;
		Sys.println(v);
		Sys.println(1 + (try fail(1) catch (e:MyError) 0));
		try {
			try throw new cs.system.ArgumentException("inner") catch (e:MyError) Sys.println("wrong");
		} catch (e:cs.system.ArgumentException) {
			Sys.println("outer " + e.Message);
		}
	}
}
===
[run]
ok 1
caught 5 my error
20
-9
2
outer inner
```

- [ ] **Step 2: Run it to see it fail**

Run: `tests/dotnet/run.sh --compiler <hxc> --std C:/HaxeToolkit/haxe/std --case exceptions`
Expected: FAIL with `dotnet: ... is not supported yet`.

- [ ] **Step 3: Check what the exceptions filter leaves**

Run: `<hxc> -cp . --main P --cs out -D dotnet -D dump=pretty` on the case and read
`dump/cs/P.dump`.
Expected: `throw new MyError(n)` and the `catch (e:MyError)` / `catch (e:cs.system.Exception)` /
`catch (e:cs.system.ArgumentException)` clauses are still native, with no `haxe.Exception.caught`
or `Std.isOfType` (Haxe 4.3.7's filter keeps types that unify with `cs.system.Exception` and aren't
`haxe.Exception`). If they aren't, stop and report: native catches would then need milestone 3's
runtime, and the case has to change.

- [ ] **Step 4: Implement**

- `TThrow` → `throw` (the exceptions filter has already wrapped values that aren't native
  exceptions).
- `TTry` → a protected region with one typed catch clause per `catch`, in order; the handler starts
  with the exception on the stack and stores it in the catch variable. A `catch` typed `Dynamic` or
  with a non-class type throws `Unsupported("catch of <type>")` (the filter only leaves native
  types here).
- Leaving a region: `return` inside a `try` or `catch` stores to a return local and `leave`s to a
  label after the region, which loads it and returns; `break`/`continue` that cross a region
  boundary `leave` instead of `br`. Each loop records the try depth it was entered at.
- `try` as a value: the region's value goes to a temp local, loaded after the region. When a `try`
  appears in an operand position, the operands evaluated before it are spilled to temp locals first,
  so the stack is empty at the region's start; `IlCode` throws an internal error if a region begins
  on a non-empty stack.

- [ ] **Step 5: Run all cases**

Run: the Task 1 build command, then `tests/dotnet/run.sh --compiler <hxc> --std C:/HaxeToolkit/haxe/std`
Expected: every case `ok`.

- [ ] **Step 6: Commit**

```bash
git add src/hxc/codegen/dotnet tests/dotnet/cases.hx.txt
git commit -m "Lower try, catch and throw to IL exception regions"
```

---

### Task 7: The milestone's exit check and documentation

**Files:**
- Modify: `README.md`
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: everything above.
- Produces: the milestone exit evidence.

- [ ] **Step 1: Write the exit case**

One program that uses everything together, as the spec's milestone 2 exit asks (*"a small program
with classes, statics, strings, arrays, exceptions"*):

```
--- inventory
class Item {
	public var name:String;
	public var qty:Int;
	public function new(name:String, qty:Int) {
		this.name = name;
		this.qty = qty;
	}
	public function toString():String {
		return name + " x" + qty;
	}
}
class OutOfStock extends cs.system.Exception {
	public function new(name:String) {
		super(name + " is out of stock");
	}
}
class Inventory {
	static var created = 0;
	var items:Array<Item> = [];
	public function new() {
		created++;
	}
	public function add(name:String, qty:Int):Void {
		items.push(new Item(name, qty));
	}
	public function take(name:String):Item {
		for (it in items) {
			if (it.name == name) {
				if (it.qty == 0) throw new OutOfStock(name);
				it.qty--;
				return it;
			}
		}
		throw new cs.system.ArgumentException("no " + name);
	}
	public static function count():Int {
		return created;
	}
}
class P {
	static function main() {
		var inv = new Inventory();
		inv.add("apple", 1);
		inv.add("pear", 0);
		Sys.println("" + inv.take("apple"));
		for (n in ["apple", "pear", "plum"]) {
			try {
				inv.take(n);
			} catch (e:OutOfStock) {
				Sys.println(e.Message);
			} catch (e:cs.system.ArgumentException) {
				Sys.println("error: " + e.Message);
			}
		}
		Sys.println(Inventory.count());
	}
}
===
[run]
apple x0
apple is out of stock
pear is out of stock
error: no plum
1
```

- [ ] **Step 2: Run the whole suite**

Run: the Task 1 build command, then `tests/dotnet/run.sh --compiler <hxc> --std C:/HaxeToolkit/haxe/std`
Expected: every case `ok` (each one is also ILVerify-clean and deterministic, which `run.sh`
checks).

- [ ] **Step 3: Check the regression suites**

Run, in `D:/_github/haxe-conformance`:
`neko run.n run --compiler <hxc> --std C:/HaxeToolkit/haxe/std --divergences D:/_github/hxc/tests/divergences.json -j 4`
and the hxc families command from Task 1 Step 8.
Expected: both pass as they did before this branch.

- [ ] **Step 4: Check that a stub report comes out sorted and path-free**

Run: `<hxc> -cp . --main P --cs out -D dotnet -D dotnet-stub-report` on the `inventory` source.
Expected: `skipped`/`stubbed` lines in sorted order, none containing a drive letter or `/`-rooted
path. (No expected text: the list shrinks as milestone 3 lands.)

- [ ] **Step 5: Document**

In `README.md`, next to the `--cs` type-checking note: `--cs <dir> -D dotnet` writes
`<name>.dll` (+ `runtimeconfig.json` with `-main`) for .NET 10; `-D dll-name`; the milestone 2
status (classes, statics, strings, arrays, native exceptions; hxcs's runtime is stubbed until
milestone 3, `-D dotnet-stub-report` lists what's stubbed); how to run `tests/dotnet/run.sh`.

- [ ] **Step 6: Commit**

```bash
git add README.md tests/dotnet/cases.hx.txt
git commit -m "Add the milestone 2 exit program and document -D dotnet"
```

---

## Left for later milestones (don't build here)

- hxcs runtime parity, `Dynamic` operations, closures and local functions, enums, anonymous
  objects, reflection, `haxe.Exception`-based throws and catches (they reach `Std.isOfType`), the
  `HxObject` base class and gencs's split constructors: milestone 3.
- Casts between instantiations of a generic class, including hxc's own `Array.hx` with the forward
  that fixes Haxe issue 8314 (spec, *Casts between generic instantiations*): milestone 3.
- Calls on value-type receivers, `@:nativeGen` details, attributes, properties, delegates/events,
  inline C#, custom modifiers in extern signatures, manifest resources: milestone 4.
- Debug directory, Portable PDB, sequence points: milestone 5.
