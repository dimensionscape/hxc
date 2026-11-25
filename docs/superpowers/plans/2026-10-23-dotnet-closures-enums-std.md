# .NET closures, enums and std (milestone 3b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Haxe enums, closures and function values, dynamic methods, 64-bit integers and the rest
of `Std`/`Type`/`Reflect`/`haxe.Exception` behave under `--cs <dir> -D dotnet` as Haxe 4.3.7 gencs +
hxcs make them behave, and a `haxe.Serializer` corpus round-trips between the two builds in both
directions.

**Architecture:** Enums are emitted directly from plans with no `TClass` (a new `EnumToIl`), in
gencs's `enumToClass2` shape: a `haxe.lang.Enum` subclass per enum and a sealed class per
constructor. Local functions go through a typed-AST pre-pass (a new `ClosuresToClass`) that turns
each `TFunction` into a synthesized `haxe.lang.Function` subclass before any type is declared, so
everything after it sees ordinary classes. Calls of function values and method closures lower to
the `haxe.lang.Function` invoke protocol and `haxe.lang.Closure`, which 3a's runtime copy already
has. hxc's runtime copy gains `Std.hx` and `Type.hx` with their inline C# rewritten in Haxe.
`run.sh` gains a `@serial` flag that runs a corpus program through both builds and swaps their
outputs.

**Tech Stack:** Haxe 4.3 (hxc's source), hxcpp via Aedifex, the .NET 10 SDK, Haxe 4.3.7 + hxcs (the
oracle; installed locally).

**Spec:** `docs/superpowers/specs/2026-10-21-dotnet10-il-generator-design.md`, milestone 3 (*Runtime
parity*), *Success* (the serialized-value corpus), *Compatibility*. The previous plan
`docs/superpowers/plans/2026-10-22-dotnet-runtime-foundation.md` (3a, done) explains what this one
builds on: hxgen classes, `__hx_*` reflection members, `Dynamic`, anonymous objects, `Null<T>`, the
`@gencs` harness, the embedded runtime.

**Milestone 3 is three plans.** 3a is merged. This is 3b. **3c** follows: `__hx_cast` and companion
interfaces for generic Haxe classes, mapping class/enum type arguments to `object` as gencs does
(3a's parked residual (b)), and the `Array` forwarding fix for Haxe issue 8314. Milestone 3's exit is
checked at the end of 3c.

**Research behind this plan** (read the notes for the task you are on; they quote real gencs output
and say where each piece plugs in): `D:/_hxc3b/closures/NOTES.md`, `D:/_hxc3b/enums/NOTES.md`,
`D:/_hxc3b/std/NOTES.md`, `D:/_hxc3b/serializer/NOTES.md`. Their probe directories hold gencs's C# for
every probe. gencs source (GPL, read only, never copied into the repo):
`C:/Users/JOEWIL~1/AppData/Local/Temp/claude/D---github-hxc/c9d8d778-a09f-433f-b6fc-7a14c96db3e0/scratchpad/ref/`
(`closuresToClass.ml`, `capturedVars.ml`, `enumToClass2.ml`, `reflectionCFs.ml`, `castDetect.ml`, …).

**Test material** lives next to this plan in `docs/superpowers/plans/2026-10-23-dotnet-closures-enums-std/`:
`closures.cases.txt`, `enums.cases.txt`, `std.cases.txt` (verified cases in `cases.hx.txt` format,
every expectation a real gencs net10.0 run), `serial/` (the corpus program and gencs's outputs),
`serverapp/` (the server app builds that reproduce the problems in Task 1 and measure Task 12). "Add case X from
F" means: copy that case's text verbatim from F to the end of `tests/dotnet/cases.hx.txt`.

**Branch:** `git switch -c dotnet-il-m3b dotnet-il-generator`. Don't push or open a PR.

## Global Constraints

- Everything 3a's Global Constraints say still holds: `net10.0`; `--cs <dir> -D dotnet`; `-D dll-name`;
  byte-identical output between two compiles; hxc writes PE/IL itself; ILVerify on every test
  assembly; no silent miscompiles; the code style of `src/hxc/codegen/jvm/` and of the surrounding
  dotnet code; commit trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Whatever stored data or the C# side can observe behaves like Haxe 4.3.7 gencs + hxcs, hxcs bugs
  included (spec *Compatibility*). The oracle is gencs's C# built for `net10.0` with
  `tests/dotnet/gencs.csproj.in`, never hxcs's own `csc` build.
- CLR names reflection or C# can see are gencs's: enum classes `<pack>.<Enum>` and
  `<pack>.<Enum>_<Ctor>`, closure classes `<Class>_<field>_<line>__Fun`, `haxe.lang.Function`,
  `haxe.lang.Closure`, `haxe.lang.Enum`, member names and member order as the research notes list.
- hxc's runtime copy contains no `__cs__`, `cs.Syntax.code`, `@:functionCode` or `@:classCode`.
- In user code, anything not supported yet is an `Unsupported` error at the construct's position,
  never an internal error and never a crash; in std code it becomes a stub (milestone 2's rule).
- Cases are compiled without `-debug` (gencs's harness build has no PDB, so stack frames read
  `(null line 0)`).
- Commands used below:
  - BUILD: `AEDIFEX_ROOT=D:/_github/hxc-toolchain/aedifex/ HAXE_STD_PATH=C:/HaxeToolkit/haxe/std HXCPP_COMPILE_CACHE=D:/_github/hxc-toolchain/hxcpp-cache haxelib run aedifex build cpp .`
  - CASE `<name>`: `tests/dotnet/run.sh --compiler bin/cpp/windows/x64/release/bin/hxc.exe --std C:/HaxeToolkit/haxe/std --case <name>`
  - ALL: the same without `--case`; expected `all N cases passed`.

## Review Focus

1. **The server app's build flags** (`-dce full -D analyzer-optimize -D net-ver=40`): DCE must keep enum
   constructor classes, closure classes, `__hx_constructs` and the Serializer's paths, exactly as
   gencs keeps them. Test: `serverapp-flags` (`@gencs`) in Task 12.
2. **Enum constructors used as function values, and enum matching inside closures**
   (`[1, 2].map(Some)`, a lambda switching on a captured enum). Test: `enum-constructor-values`
   (`@gencs`) in Task 9.
3. **Calling a static or instance variable of function type** (`C.sf(x)`), which today aborts the
   whole compile with `internal error: no method P.sf`, and calling one that is `null`. Test:
   `function-fields` (`@gencs`) in Task 8.
4. **A method the typer knows never falls through** (an endless loop left only by `return`/`throw`,
   a switch whose every branch throws) failing as `internal error: a non-void method falls off its
   end` with no position, which stops the server app's whole server build. Test: the `falls-off-end-*` case
   Task 1 extracts from the server app.
5. **Exceptions thrown inside closures** (a lambda, an instance method closure, a static method
   closure called through `Reflect.callMethod`) reach the caller's typed `catch` the way they do
   under gencs. Test: `closure-exceptions` (`@gencs`, gencs's output is the expectation) in Task 9.

---

## File structure

| File | Responsibility |
| --- | --- |
| `src/hxc/codegen/dotnet/EnumToIl.hx` (new) | Plans, metadata and bodies of enum classes |
| `src/hxc/codegen/dotnet/ClosuresToClass.hx` (new) | Typed-AST pre-pass: `TFunction` → synthesized `haxe.lang.Function` subclasses |
| `src/hxc/codegen/dotnet/TexprCalls.hx` | Function-value calls, method closures, `FEnum` reads and calls, `__array__` |
| `src/hxc/codegen/dotnet/TexprOps.hx` | Int64/UInt64 operators, `cs.Flags` operators, `Class`/`Enum` equality |
| `src/hxc/codegen/dotnet/TexprToIl.hx` | `TEnumIndex`/`TEnumParameter`, the checked cast into generic instantiations, `finish()` diagnostics, `TFor` safety net |
| `src/hxc/codegen/dotnet/TclassToIl.hx` | Dynamic methods, overrides that change the signature |
| `src/hxc/codegen/dotnet/GenerateDotnet.hx`, `DotnetTypes.hx` | Enum planning, `toSig` of enums, running the pre-pass |
| `src/hxc/codegen/dotnet/runtime/Std.hx`, `runtime/Type.hx` (new) | hxc's copies of hxcs's `Std`/`Type` without inline C# |
| `tests/dotnet/run.sh` | `@serial`; no MSBuild node reuse in the batch build |
| `tests/dotnet/cases.hx.txt` | The new cases |
| `README.md` | The .NET section's feature list |

---

### Task 1: Find the method that falls off its end, and harden the harness

The server app build stops at the first method `finish()` thinks falls off its end, with no class,
method or position (`TexprToIl.hx:209` throws a plain string). Find it, fix the reachability rule it
exposes, and make the message useful for the next one.

**Files:**
- Modify: `src/hxc/codegen/dotnet/TexprToIl.hx`, `src/hxc/codegen/dotnet/TexprFlow.hx`, `tests/dotnet/run.sh`
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Produces: nothing other tasks call.

- [ ] **Step 1: Make the error name the method**

In `finish()`, replace the string throw with an `Unsupported` placed at the method's position whose
message names `<Haxe class path>.<field>` and says it is an hxc bug:
`"<pk.C.m> falls off its end without a return (an hxc reachability bug)"`. Clear the
`exhaustiveSwitch` flag at the end of each switch rather than leaving it set for the rest of the
method (3a deferred finding: today it turns a later real fall-off into a silent default return).

- [ ] **Step 2: Reproduce on the server app**

BUILD, then from `<server-app>/haxe` (read only; never
change anything there) run `<hxc> D:/_github/hxc/docs/superpowers/plans/2026-10-23-dotnet-closures-enums-std/serverapp/server-dotnet.hxml`
with `HAXE_STD_PATH=C:/HaxeToolkit/haxe/std`. Expected: the new message with a position. Read that
method.

- [ ] **Step 3: Write the failing case**

Reduce the method to a `falls-off-end-<shape> @gencs` case (`<shape>` names what it is, e.g.
`while-true-return`, `switch-all-throw`, `throw-in-try`) that prints something before and after the
call. CASE it: expected FAIL with the new message.

- [ ] **Step 4: Fix reachability in `TexprFlow`**

Make `code.reachable()` false after the construct the case exercises, matching what Haxe's typer
already knows (an `while (true)` with no `break` is never left at its end; a `switch`/`if` whose
every branch ends unreachable is unreachable; a `try` whose body and every catch end unreachable is
unreachable). Re-run the server app build and repeat Steps 3-4 for each further method it reports until
the build gets past code generation's reachability check (other errors it reports are Task 12's).

- [ ] **Step 5: `TFor` safety net and harness hardening**

- `TexprToIl`: replace `case TFor: throw new Unsupported("for loops")` with the JVM backend's
  fallback (`TexprToJvm.hx:1999`): lower `forRemap`'s output. hxc's `ForRemap` filter already removes
  every `TFor`, so no case reaches it.
- `run.sh`: run the batch `dotnet build` with `MSBUILDDISABLENODEREUSE=1` (an idle reused MSBuild
  node hung the whole `@gencs` build for 75 minutes during 3a).

- [ ] **Step 6: Run everything and commit**

ALL: expected every case passes. Commit: `Name the method that falls off its end and fix <shape> reachability`.

---

### Task 2: 64-bit integers (and so `Date`)

`cs.StdTypes.Int64`/`UInt64` have no operators today, which stubs `Date.getTime`/`fromTime`/
`getTimezoneOffset`, `DateTools.format`, `haxe.Int64` and all of `Unserializer.unserialize` (its `v`
branch inlines `Date.fromTime`). Most of the "Dynamic operators in std" errors the server app shows are these.

**Files:**
- Modify: `src/hxc/codegen/dotnet/TexprOps.hx`, `src/hxc/codegen/dotnet/TexprToIl.hx` (`convert`, `castExpr`)
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Produces: `LInt64`/`LUInt64` take part in `TexprOps`'s numeric operators and `convert`'s
  conversions; later tasks rely on `Date` and `Unserializer` compiling.

- [ ] **Step 1: Add the cases**

Add `int64-arithmetic` and `date-time` from `std.cases.txt`.

- [ ] **Step 2: Run them**

CASE each: expected FAIL ("the + operator on these types", "conversions between value types").

- [ ] **Step 3: Implement the operators and conversions**

As C# binds them, which is what gencs prints:
- `+ - * / %`, unary `-`, `| & ^ ~`, `<< >> >>>`, comparisons, compound assignment and `++`/`--` on
  Int64/UInt64. An `Int` operand widens with `conv.i8` (with UInt64: `conv.u8`); a `Float` operand
  makes the operation Float (`conv.r8`; UInt64 first `conv.r.un`). `/` and `%` of two integer
  operands are integer `div`/`rem` (`div.un`/`rem.un` for UInt64), even though Haxe types `/` as Float:
  `5000000000 / 3` prints `1666666666`, `UInt64 max / 2` prints `9223372036854775807`. Shifts take an
  int32 count; `>>` of UInt64 and `>>>` are `shr.un`. Overflow wraps.
- Conversions: Int64 → Float `conv.r8`, UInt64 → Float `conv.r.un; conv.r8`, Int64 → Int `conv.i4`,
  Float → Int64 `conv.i8`, Int → Int64 `conv.i8`, boxing as `int64`/`uint64`.
- gencs's checked-cast quirk: `cast(x, T)` where `T` or `x`'s type is Int64/UInt64 converts nothing
  itself. The value keeps `x`'s type and converts only where its destination forces it
  (`cast(-2.7, Int64)` printed is `-2.7`; `cast(a, Int)` of a 5000000000 Int64 printed is
  `5000000000`; `Date.fromTime`'s `new DateTime(long)` argument still gets `conv.i8`).

- [ ] **Step 4: Run them**

CASE each: expected `ok`. `-D dotnet-stub-report` on `date-time` lists no `Date` or `DateTools` method.

- [ ] **Step 5: Run everything and commit**

ALL. Commit: `Lower Int64 and UInt64 arithmetic for .NET`.

---

### Task 3: `cs.Flags`, `Class` equality, Dynamic nulls into value types

These three stub `Type.getClassFields`/`getInstanceFields`/`getEnumConstructs` and
`Reflect.instanceFields` (so `Reflect.fields` of Strings, native objects and `Class` values).

**Files:**
- Modify: `src/hxc/codegen/dotnet/TexprOps.hx`, `src/hxc/codegen/dotnet/TexprToIl.hx`, `src/hxc/codegen/dotnet/DotnetTypes.hx`
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Produces: `TexprOps` lowers `==`/`!=` on `Class`/`Enum` values; Task 7 relies on it for
  `Type.resolveEnum(...) == E`.

- [ ] **Step 1: Add the cases**

Add `cs-flags-operators`, `type-fields-and-class-equality` and `reflect-api` from `std.cases.txt`.

- [ ] **Step 2: Run them**

CASE each: expected FAIL (`cs._Flags.EnumUnderlying`, "the == operator on these types", a stub).

- [ ] **Step 3: Implement**

- `cs._Flags.EnumUnderlying<T>` maps to `T` (the .NET enum). Its `|`, `&`, `^` are `or`/`and`/`xor`
  and `~` is `not` on the underlying integer; the result is the enum type.
- A `null` constant whose own type is `Dynamic`, or `cast null` to a .NET enum, going into a value
  type is `defaultValue(to)`: `Reflect.compare((null:Dynamic), 1)` gives gencs's 0 path,
  `new Flags<BindingFlags>()` prints `Default`. A plain `null` into a value type stays refused.
- `==`/`!=` where an operand's type is `Class<…>`/`Enum<…>` or a type expression's statics type:
  `Runtime.typeEq(a, b)` when both static types are `Class<…>`/`Enum<…>` (not `Dynamic`) or one side
  is the `null` constant (`typeEq(x, null)`), otherwise `Runtime.refEq(a, b)` (a type expression
  operand, `Class<Dynamic>`). `!=` negates. Both helpers exist in hxc's runtime copy.

- [ ] **Step 4: Run them**

CASE each: expected `ok`.

- [ ] **Step 5: Run everything and commit**

ALL. Commit: `Lower cs.Flags operators and Class equality for .NET`.

---

### Task 4: hxc's own `Std`/`Type`, the checked cast into generic instantiations, overrides that change the signature

**Files:**
- Create: `src/hxc/codegen/dotnet/runtime/Std.hx`, `src/hxc/codegen/dotnet/runtime/Type.hx`
- Modify: `src/hxc/codegen/dotnet/TexprToIl.hx`, `src/hxc/codegen/dotnet/ReflectionMembers.hx`, `src/hxc/codegen/dotnet/TclassToIl.hx`
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Produces: `TexprToIl.checkedInstanceCast(to:IlSigNorm, what:String):Void`, which takes an
  `object` on the stack and leaves `to` (null and the same instantiation pass, anything else throws
  `System.NotSupportedException("hxc dotnet: converting " + what + " is not supported yet")`). Task 6
  (enum parameters typed `Array<X>`) and Task 11 (Unserializer output) rely on it.

- [ ] **Step 1: Add the cases**

Add `std-isoftype-and-create-instance`, `std-string-formatting` and `std-parse-and-int` from
`std.cases.txt` (the last two pass today; they guard float formatting and the parse quirks), and:

```
--- generic-from-dynamic @gencs
class P {
	static function main() {
		var sm = new haxe.ds.StringMap<Dynamic>();
		sm.set("a", 1);
		var d:Dynamic = sm;
		var v:haxe.ds.StringMap<Dynamic> = d;
		for (k in v.keys()) Sys.println(k + "=" + v.get(k));
		var l = new List<Dynamic>();
		l.add(1);
		d = l;
		var lv:List<Dynamic> = d;
		for (i in lv) Sys.println(i);
		var im = new haxe.ds.IntMap<Dynamic>();
		im.set(3, "x");
		d = im;
		var iv:haxe.ds.IntMap<Dynamic> = d;
		for (k in iv.keys()) Sys.println(k);
		var om = new haxe.ds.ObjectMap<Dynamic, Dynamic>();
		om.set(sm, 2);
		d = om;
		var ov:haxe.ds.ObjectMap<Dynamic, Dynamic> = d;
		for (k in ov.keys()) Sys.println(ov.get(k));
		var none:haxe.ds.StringMap<Dynamic> = (null : Dynamic);
		Sys.println(none == null);
	}
}
===
[run]
a=1
1
3
2
True
--- generic-from-dynamic-other-instantiation
class P {
	static function main() {
		var d:Dynamic = new haxe.ds.StringMap<Int>();
		try {
			var v:haxe.ds.StringMap<Dynamic> = d;
			Sys.println(v);
		} catch (e:cs.system.NotSupportedException) {
			Sys.println(e.Message);
		}
	}
}
===
[run]
hxc dotnet: converting a value to haxe.ds.StringMap<Dynamic> is not supported yet
--- override-changes-signature @gencs
class Shape {
	public var n:Int;
	public function new(n) this.n = n;
}
class Tree<K> {
	public function new() {}
	function compare(a:K, b:K):Int return 0;
	public function cmp(a:K, b:K):Int return compare(a, b);
}
class ShapeTree<K:Shape> extends Tree<K> {
	public function new() super();
	override function compare(a:Shape, b:Shape):Int return a.n - b.n;
}
class P {
	static function main() {
		var t = new ShapeTree<Shape>();
		Sys.println(t.cmp(new Shape(5), new Shape(2)));
		var u:Tree<Shape> = t;
		Sys.println(u.cmp(new Shape(1), new Shape(4)));
	}
}
===
[run]
3
-3
```

`generic-from-dynamic-other-instantiation` is hxc-only and records a divergence 3c removes (gencs
copies through `__hx_cast`).

- [ ] **Step 2: Run them**

CASE each: expected FAIL for all but `std-string-formatting` and `std-parse-and-int`.

- [ ] **Step 3: `runtime/Std.hx` and `runtime/Type.hx`**

Copy Haxe 4.3.7's `std/cs/_std/Std.hx` and `Type.hx` (MIT; keep the header) into the embedded
runtime's root and replace their inline C# with 3a's magic identifiers, keeping `@:coreApi`, `Std`'s
`@:nativeGen`, every signature and gencs's behavior (`D:/_hxc3b/std/NOTES.md` §2 quotes the C# they
compile to):
- `Std.isOfType`: `'{0} is double || {0} is int'` → `__is__(v, Float) || __is__(v, Int)`, `'{0} is bool'`
  → `__is__(v, Bool)`.
- `Type.createEmptyInstance`: `(T)(object)""` for `String`, else
  `Activator.CreateInstance(t, [EmptyObject.EMPTY])` falling back to `Activator.CreateInstance(t)` on
  `MissingMemberException`, then a cast to `T` (`unbox.any !!T`).
Check with `-v` or a probe that these files shadow `cs/_std` (the runtime root must come first on the
class path); if they don't, fix the order in `Setup`.

- [ ] **Step 4: The checked cast**

Move the block `ReflectionMembers` emits for a generic Haxe class (around line 374) into
`TexprToIl.checkedInstanceCast`; `ReflectionMembers` calls it with
`what = <Haxe type> + " through reflection"`. `convert` from `LObject` (a `Dynamic` source) to an
instantiation of a generic Haxe class calls it with `what = "a value to " + <Haxe type>` instead of
`castTo`'s compile-time refusal. Casts between two known instantiations stay compile errors.

- [ ] **Step 5: Overrides that change the signature**

Where `TclassToIl` now refuses "overrides that change the signature" (around line 515), emit the
override with the overridden method's CLR signature, as gencs does: parameters named
`__temp_<name><position>` (1-based: `__temp_a1`, `__temp_b2`), and the body starting with locals of
the declared names and types converted from them (`coerce`); a return value converts back to the
base method's return type. This compiles `haxe.ds.EnumValueMap.compare`.

- [ ] **Step 6: Run them**

CASE each: expected `ok`. `-D dotnet-stub-report` on `std-isoftype-and-create-instance` lists no
`Std.*` or `Type.*` method.

- [ ] **Step 7: Run everything and commit**

ALL. Commit: `Ship Std and Type without inline C#, cast Dynamic into generic instantiations`.

---

### Task 5: Enum classes and construction

**Files:**
- Create: `src/hxc/codegen/dotnet/EnumToIl.hx`
- Modify: `src/hxc/codegen/dotnet/GenerateDotnet.hx`, `src/hxc/codegen/dotnet/DotnetTypes.hx`, `src/hxc/codegen/dotnet/TexprCalls.hx`, `src/hxc/codegen/dotnet/TexprOps.hx`, `src/hxc/codegen/dotnet/TclassToIl.hx` (`FieldAttrs`)
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Produces: `DotnetCtx.enumPlans:haxe.ds.ObjectMap<TEnum, EnumPlan>`, where `EnumPlan` holds the
  tokens of the base TypeDef, each constructor TypeDef, each singleton field, each factory method and
  each parameter field (by constructor and argument index), plus `haxe.lang.Enum::_hx_index`.
  `DotnetTypes.toSig(TEnum(e, _))` of an hxgen enum is `LClass(<base path>, [])` (type parameters
  erased). `EnumToIl.argSig(ef, i):IlSigNorm` is the erased type of constructor `ef`'s argument `i`.
  Tasks 6, 7 and 9 use these.

- [ ] **Step 1: Add the cases**

Add `enum-shape` and `enum-strings` from `enums.cases.txt`.

- [ ] **Step 2: Run them**

CASE each: expected FAIL ("enums are not supported yet").

- [ ] **Step 3: Declare enums**

`D:/_hxc3b/enums/NOTES.md` §1 is the shape, member for member; `enum-shape`'s `[dump]` pins it.
Decisions:
- Plan hxgen enums (`HxGen.isHxGen(TEnumDecl(e))`; flat `@:nativeGen` enums stay CLR enums) before
  classes, with `ClassPlan`s that have `c: null` and new `MethodKind`s, emitted directly in
  `emitPlan` (the `entryPointClass` pattern), not as synthesized `TClass`es.
- Register the base path and every `<Enum>_<Ctor>` path in the name-collision map; a collision is a
  compile error.
- Argument types: apply the enum's and the constructor's type parameters as `Dynamic`, then
  `argSig`. An argument whose erased type is an instantiation of a generic Haxe class *with a type
  parameter of the enum* (`Array<T>`, which gencs types as its companion interface) is refused:
  `Unsupported("enum arguments of generic class types")` until 3c. Other generic arguments
  (`Array<Shape>`) map as elsewhere; that hxc writes ``Array`1<Shape>`` where gencs writes
  ``Array`1<object>`` belongs to 3c's type-argument decision (residual (b)).
- `__hx_constructs` (`family static initonly string[]`) is emitted on every enum only when hxc's
  feature tracking marks `Type.getEnumConstructs` as used, as gencs's `ctx.hasFeature` does.
- `FieldAttrs` gains `INIT_ONLY = 0x20` and `FAMILY = 0x4`.

- [ ] **Step 4: Construction and printing**

`TexprCalls.fieldRead` of `FEnum` without arguments is `ldsfld` of the singleton (never `newobj` at a
use site). `TexprCalls.call` of `FEnum` pushes each argument converted to its *instantiated* Haxe type
first, then to the erased factory parameter (`Some(2)` for `Opt<Float>` boxes a `float64`), and calls
the factory. String concatenation of an enum operand prints through `Std.string`. A constructor
with arguments read as a value stays refused until Task 8.

- [ ] **Step 5: Run them**

CASE each: expected `ok`.

- [ ] **Step 6: Run everything and commit**

ALL. Commit: `Emit Haxe enums as gencs's enum classes`.

---

### Task 6: Enum matching, parameters and equality

**Files:**
- Modify: `src/hxc/codegen/dotnet/TexprToIl.hx`, `src/hxc/codegen/dotnet/EnumToIl.hx`, `src/hxc/codegen/dotnet/TexprDynamic.hx`
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: `EnumPlan` (Task 5), `checkedInstanceCast` (Task 4).

- [ ] **Step 1: Add the cases**

Add `enum-switch`, `enum-equality` and `enum-generic-params` from `enums.cases.txt`.

- [ ] **Step 2: Run them**

CASE each: expected FAIL ("enum values").

- [ ] **Step 3: Implement**

- `TEnumIndex(e)` of an hxgen enum: `ldfld haxe.lang.Enum::_hx_index`.
- `TEnumParameter(e, ef, i)`: `isinst <Enum>_<Ctor>; ldfld <param i>`, then `coerce` from
  `EnumToIl.argSig(ef, i)` to the expression's type through the existing conversions (`Runtime.toInt`,
  `toDouble`, `toString`, `genericCast`, and `checkedInstanceCast` for `Array<X>`).
- `==`/`!=` and `null` comparisons of enum values are reference compares; `Null<E>` is the plain class.
- `Std.isOfType(v, E)` is `isinst <Enum base>`.
- The generated `Equals(object)` and `GetHashCode()` follow the notes' shape (`ReferenceEquals`,
  `isinst`, `Type.enumEq<object>` per parameter, `haxe.lang.Enum.paramsGetHashCode`); parameters go into
  `object[]` converted to Dynamic the usual way (`Null<T>` via `toDynamic()`).

- [ ] **Step 4: Run them**

CASE each: expected `ok`.

- [ ] **Step 5: Run everything and commit**

ALL. Commit: `Lower enum matching, parameters and equality`.

---

### Task 7: `Type.typeof`, the enum `Type`/`Reflect` API, exception stacks, enums through the Serializer

With enums declarable, `ValueType` compiles, and so does all of `Type`; `haxe.StackItem` compiles, so
does `haxe.Exception.stack`; `haxe.io.Encoding` compiles, so does `haxe.io.Bytes`.

**Files:**
- Modify: whatever the cases expose; expect `EnumToIl.hx`, `TexprCalls.hx`, the runtime copy's `HxObject.hx`
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: Tasks 2-6.

- [ ] **Step 1: Add the cases**

Add `enum-type-api`, `enum-reflect` and `enum-serialize` from `enums.cases.txt`, and `type-typeof`,
`exception-stack-and-details` and `haxe-exceptions` from `std.cases.txt`.

- [ ] **Step 2: Run them**

CASE each: record which fail and why (`haxe-exceptions` passes today and must keep passing).

- [ ] **Step 3: Fix what they expose**

Expected pieces (each named in the enums and std notes): `slowGetField`/`slowCallField` finding the
public static singletons and factories by exact name; `__hx_constructs` non-public so
`Type.getEnumConstructs` finds it; `v.GetType()` on `Dynamic` as a direct `callvirt
System.Object::GetType` in `Type.typeof`; `Type.enumEq`'s and `resolveEnum`'s `untyped` member calls
not hitting the "untyped code" refusal; frames reading `P.thrower`/`P.main`/`P.Main`. The empty line
`enum-reflect` expects for an unset `?n:Int` (the boxed `haxe.lang.Null<int>` struct) is gencs's
behavior; keep it.

- [ ] **Step 4: Run them**

CASE each: expected `ok`. `-D dotnet-stub-report` on `enum-serialize` and `type-typeof` lists no
`Type.*`, `Reflect.*`, `haxe.Serializer`, `haxe.Unserializer`, `haxe.Exception` or `haxe.io.Bytes`
method.

- [ ] **Step 5: Run everything and commit**

ALL. Commit: `Make Type, Reflect, exception stacks and the Serializer work with enums`.

---

### Task 8: Function values and method closures

**Files:**
- Modify: `src/hxc/codegen/dotnet/TexprCalls.hx`
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Produces: `TexprCalls.invokeFunction(ret:Ret, e:TExpr, callee:TExpr, args:Array<TExpr>):Void` (the
  invoke protocol for any callee that is not a method) and
  `TexprCalls.pushClosure(receiver:Null<TExpr>, owner:IlSigNorm, name:String):Void` (a
  `haxe.lang.Closure` on the stack). Task 9's synthesized classes override the methods this calls.

- [ ] **Step 1: Add the cases**

Add `method-closures` from `closures.cases.txt`, and:

```
--- function-fields @gencs
class C {
	public static var sf:Int->Int;
	public static var none:Int->Int;
	public var f:String->String;
	public function new() {}
}
class P {
	static function inc(x:Int) return x + 1;
	static function bang(s:String) return s + "!";
	static function main() {
		C.sf = inc;
		Sys.println(C.sf(2));
		var c = new C();
		c.f = bang;
		Sys.println(c.f("hi"));
		var g = c.f;
		Sys.println(g("yo"));
		try {
			C.none(1);
		} catch (e:cs.system.NullReferenceException) {
			Sys.println("null function");
		}
	}
}
===
[run]
3
hi!
yo!
null function
```

- [ ] **Step 2: Run them**

CASE each: expected FAIL (`function-fields` aborts the compile with `internal error: no method C.sf`).

- [ ] **Step 3: The invoke protocol**

For every callee that is not a method (a local, an expression, a `Dynamic`, a variable field of
function type on a class, extern or statics), as `D:/_hxc3b/closures/NOTES.md` §3.2:
- Each argument is a pair: float-like real type (abstracts unwrapped, not Int64) →
  `(conv.r8 arg, ldsfld Runtime.undefined)`, otherwise `(0.0, box arg)`.
- Arity < 6: `__hx_invoke<N>_f` when the call's return type is float-like (not `Null<T>`, not Int64),
  then convert (`conv.i4` for Int); else `__hx_invoke<N>_o` and convert from `object`.
  Arity ≥ 6: `__hx_invokeDynamic(object[])` with boxed arguments.
- A `Dynamic` callee is `castclass haxe.lang.Function`, then always `_o`.
- Calls on anonymous objects and `Dynamic` fields keep 3a's `Runtime.callField`.
This replaces the `FStatic` var branch that throws the internal error (`TexprCalls.call`, around
line 425).

- [ ] **Step 4: Method closures**

`FClosure`, and `FStatic`/`FInstance` of a method read as a value (Haxe, extern, String, std statics),
become `new haxe.lang.Closure(receiver, "<name>", FieldHashes.hash(name))`; a static method's
receiver is `typeof(C)` (`ldtoken; GetTypeFromHandle`). The receiver is evaluated once, at creation.
A method of `Array<Dynamic>` goes through `Runtime.getField(arr, name, hash, true)` as gencs does. An
enum constructor with arguments read as a value is `new Closure(typeof(<Enum base>), "<Ctor>", hash)`.
Reuse what `ReflectionMembers.getCase` emits (around line 653).

- [ ] **Step 5: Run them**

CASE each: expected `ok`. `-D dotnet-stub-report` on `method-closures` no longer lists
`Array.map`, `Array.filter`, `Array.quicksort` or `VarArgsFunction.__hx_invokeDynamic`.

- [ ] **Step 6: Run everything and commit**

ALL. Commit: `Call function values and create method closures`.

---

### Task 9: Closure classes for local functions

**Files:**
- Create: `src/hxc/codegen/dotnet/ClosuresToClass.hx`
- Modify: `src/hxc/codegen/dotnet/GenerateDotnet.hx`, `src/hxc/codegen/dotnet/TexprCalls.hx` (`magicCall`), `src/hxc/codegen/dotnet/TexprToIl.hx`
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: `invokeFunction` (Task 8), `EnumPlan` (Tasks 5-6).
- Produces: `ClosuresToClass.run(candidates:Array<TClass>):Array<TClass>`, returning the synthesized
  classes; `GenerateDotnet.generate` calls it before planning and appends them to the candidates.

- [ ] **Step 1: Add the cases**

Add `closure-captures`, `closure-identity`, `closure-generic`, `closure-equality`,
`function-value-calls` and `dynamic-int-results` from `closures.cases.txt`, and:

```
--- enum-constructor-values @gencs
enum Opt {
	Some(v:Int);
	None;
}
class P {
	static function main() {
		var f = Some;
		Sys.println(f(3));
		Sys.println([1, 2].map(Some));
		var g:Int->Opt = Some;
		var o = g(4);
		var h = () -> switch (o) {
			case Some(v): v * 2;
			case None: 0;
		};
		Sys.println(h());
	}
}
===
[run]
Some(3)
[Some(1),Some(2)]
8
--- closure-exceptions @gencs
class C {
	public function new() {}
	public function fail():Int throw "instance";
	public static function sfail(x:Int):Int throw new haxe.exceptions.ArgumentException("x", "static");
}
class P {
	static function report(f:() -> Void) {
		try {
			f();
		} catch (e:String) {
			Sys.println("String " + e);
		} catch (e:haxe.Exception) {
			Sys.println(Type.getClassName(Type.getClass(e)) + " " + e.message);
		} catch (e:Dynamic) {
			Sys.println("other " + Type.getClassName(Type.getClass(e)));
		}
	}
	static function main() {
		report(() -> throw "lambda");
		var c = new C();
		var m = c.fail;
		report(() -> m());
		report(() -> Reflect.callMethod(C, Reflect.field(C, "sfail"), [1]));
		report(() -> [1].map(x -> x == 1 ? throw "in map" : x));
	}
}
===
```

`closure-exceptions` has no `[run]` section: gencs's output becomes the expectation.

- [ ] **Step 2: Run them**

CASE each: expected FAIL ("local functions").

- [ ] **Step 3: The pre-pass**

`D:/_hxc3b/closures/NOTES.md` §3.1 is the shape, rule by rule. Decisions:
- Map each candidate's method, constructor, variable-initializer and dynamic-method expressions into
  *new* expressions (never mutate `cf.expr` in place: the compilation server reuses typed modules).
- Each `TFunction` becomes a synthesized `TClass` extending `haxe.lang.Function`, public, in the
  enclosing class's package and module (so `isStd`/`checkKept` behave), named
  `<Class>_<field>_<line>__Fun` with `<field>` the method name, `__hx_ctor_<pack>_<Class>` inside a
  constructor (TclassToIl's split-constructor name), `Anon` in static initializers, and the variable
  name for a local generic function; repeated names in one enclosing type get `_0`, `_1`, … counting
  backwards so the last one created keeps the plain name.
- Captured locals become public fields and constructor parameters, sorted by name then reversed;
  the type parameters the body uses become the class's. `super(arity, type)` with `type` 1 for a
  float-like declared return type (not Int64, not `Null<T>`, not an `enum abstract` without
  `from`/`to`) and 0 otherwise.
- The body becomes an override of `__hx_invoke<N>_f`/`_o` (arity < 6) or `__hx_invokeDynamic`
  (arity ≥ 6) that unpacks arguments last to first as the notes show (defaults, `?x:Int`).
- No captures and no type parameters: a cached `public static __hx_current`, created on first use;
  a local generic function is never cached.
- The `TFunction` is replaced by `TNew(closureClass, params, capturedLocals)` or the
  `__hx_current` read.
- `TexprCalls.magicCall` gains `__array__(e1, …)`: `newarr` of `e.type`'s element type, then
  `dup; ldc.i4 i; <ei>; stelem` per element. hxc's `CapturedVars` filter already boxes written
  captures this way.
- `TexprToIl`'s `TFunction` case becomes an internal error: the pre-pass removed them all.

- [ ] **Step 4: Run them**

CASE each: expected `ok`. The `[dump]`-free cases check names through `Std.string` and
`Type.getClassName`, so a naming slip shows as a diff.

- [ ] **Step 5: Run everything and commit**

ALL. Commit: `Lower local functions to gencs's closure classes`.

---

### Task 10: Dynamic methods

**Files:**
- Modify: `src/hxc/codegen/dotnet/TclassToIl.hx`, `src/hxc/codegen/dotnet/ReflectionMembers.hx`
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: `ClosuresToClass` (Task 9) turns the method bodies into closure classes.

- [ ] **Step 1: Add the cases**

Add `dynamic-methods` and `for-loop-closures` from `closures.cases.txt`.

- [ ] **Step 2: Run them**

CASE each: expected FAIL ("dynamic methods") for the first; the second may already pass after Task 9.

- [ ] **Step 3: Implement**

A `dynamic function` is a public field of type `haxe.lang.Function`. The instance field is set in
the split constructor, after the super call (an override assigns it again in the subclass's split
constructor); the static field is set in the static constructor in field order with the other static
initializers. Calls go through `invokeFunction`; reading it is the field, not a `Closure`;
`Reflect.setField` replaces it. Reflection lists it as a variable, in gencs's order
(`Reflect.fields` → `[fmt,n]`, `Type.getInstanceFields` → `[n,fmt]`).

- [ ] **Step 4: Run them**

CASE each: expected `ok`.

- [ ] **Step 5: Run everything and commit**

ALL. Commit: `Support dynamic methods for .NET`.

---

### Task 11: The `@serial` harness and the corpus

**Files:**
- Modify: `tests/dotnet/run.sh`, `README.md`
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: everything above. A `@serial` program takes `gen <file>` (writes `name<TAB>serialized`
  lines, UTF-8 without BOM, `\n`, and prints them with multi-key StringMap/ObjectMap entries sorted)
  and `rt <in> <file>` (reads such a file, unserializes and re-serializes each line).

- [ ] **Step 1: `@serial` in run.sh**

As `D:/_hxc3b/serializer/NOTES.md` §3: `@serial` implies `@gencs` (and so refuses `@lib`). The gencs
side runs `gen gen.txt` (stdout is the `[run]` comparison as now) and `rt gen.txt rt.txt` (gencs
reading itself: the reference, printed under `[rt]`). The hxc side runs `gen`, then `rt` of gencs's
file, gencs's `rt` of hxc's file, and hxc's `rt` of its own file; each that differs from the reference
adds `[rt hxc<-gencs]`, `[rt gencs<-hxc]` or `[rt hxc<-hxc]` with its output, which fails the case. A
case without an `[rt]` section takes gencs's as its expectation, as for `[run]`. Document `@serial`
in the header comment.

- [ ] **Step 2: The corpus cases**

`serial/P.hx` is the program, `serial/expected.gen.txt` and `serial/expected.rt.txt` gencs's
outputs (with `-D net-ver=40`, which the server app uses and which changes `Date`). Split out the entries that
depend on the machine's time zone (`date2`, `dategap`, `in.datestr`): under `-D corpus_dates` the
program emits only those, otherwise everything else. Add:
- `serial-corpus @serial + -D net-ver=40`: `serial/P.hx`, `[run]` = `expected.gen.txt` and
  `[rt]` = `expected.rt.txt`, each without the three zone-dependent lines.
- `serial-dates @serial + -D net-ver=40 -D corpus_dates`: the same program, no expectation (gencs's
  output becomes it).
Leave the `#if corpus_typed` entries out; 3c adds them.

- [ ] **Step 3: Run them**

CASE each: expected `ok`, with no `[rt …]` section. If a line differs, the fix belongs to the task
whose area it is in; record each such fix in the ledger.

- [ ] **Step 4: README, run everything and commit**

Add `@serial` to the README's description of the .NET tests. ALL. Commit: `Round-trip a Serializer corpus between gencs and hxc builds`.

---

### Task 12: The server app measurement, interface variables, the remaining std errors

**Files:**
- Modify: as the measurement requires; `README.md`
- Test: `tests/dotnet/cases.hx.txt`

- [ ] **Step 1: Measure**

From `<server-app>/haxe` run the nativepdf build
(`serverapp/dotnet.hxml`) and the server build (`serverapp/server-dotnet.hxml`) and group their errors by
innermost cause. Record the counts in the ledger next to the 3a numbers (nativepdf: 290 errors, ~135
of them enums, ~69 Array instantiation casts, 17 local functions, 9 method closures, 6 calls of
function values, 13 untyped code, 2 `@:classCode`, ~30 operators in std, 4 interface variables, 4
dynamic methods).

- [ ] **Step 2: Interface variables**

Probe how gencs compiles a `var` in an hxgen interface and its implementations (and the reflection
members it gets), write an `interface-variables @gencs` case from the probe, and implement it in
`TclassToIl` (today: "interface variables", `TclassToIl.hx:181`).

- [ ] **Step 3: The server app's flags**

Add `serverapp-flags @gencs + -dce full -D analyzer-optimize -D net-ver=40`: a program that declares an
enum with and without arguments, matches it inside a lambda, keeps a dynamic method, and prints
`haxe.Serializer.run` / `Unserializer.run` of an enum value and an anonymous object. No `[run]`:
gencs's output is the expectation.

- [ ] **Step 4: What is left**

Every remaining error in either the server app build must have a cause outside 3b: a cast between generic
instantiations (3c), `untyped __cs__`/`@:classCode` C# text (the server app's side), or an interop feature
milestone 4 lists. Fix any other with its own `@gencs` case in this task.

- [ ] **Step 5: README, run everything and commit**

Update the README's .NET feature list (enums, closures, dynamic methods, Int64, Std/Type/Reflect, the
Serializer). ALL. Commit: `Measure milestone 3b on the server app and support interface variables`.
