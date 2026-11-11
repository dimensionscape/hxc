# hxc

**A Haxe 4.3 compiler, written in Haxe.**

hxc parses, types, runs macros and generates code for real Haxe projects. It is a drop-in
replacement for Haxe 4.3.7: the same command line, the same `.hxml` files and the same error
messages, and for the targets it supports, the same output. It is self-hosting: hxc compiles its own
source into a working compiler.

Because hxc is written in Haxe, anyone who writes Haxe can read, debug and extend the compiler in the
editor they already use. Targets, filters and tooling are ordinary Haxe modules.

hxc is the compiler underneath **[hx+](https://hxplus.org)**, a strict superset of Haxe 4.3.

```bash
hxc build.hxml          # wherever you would have typed `haxe build.hxml`
```

## Status

hxc tracks Haxe **4.3.7**. Where a target is supported, the goal is identical output, not similar
output.

| Area | State |
| --- | --- |
| Parser, typer, abstracts, `@:multiType`, static extensions, the Haxe 4 type system | Supported |
| Macros: init, build and expression macros, `haxe.macro` APIs, `sys` in the macro world | Supported, in hxc's own eval interpreter |
| `--js` | Supported |
| `--cpp`, `--cppia` | Supported, using hxcpp to build. `--cpp` also works as khamake's `--haxe` (Kha): the generated C++ matches Kha's Haxe file for file, including `@:functionCode`/`@:functionTailCode`, `-D include-prefix` and `@:headerInclude`. `Build.xml`/`Options.txt` are still written, as Haxe 4.3.7 does (Kode's fork does not; kmake never reads them) |
| `--interp`, `--run` | Supported |
| `--xml`, `--json` type descriptions | Supported |
| Compilation server | `--wait stdio` and `--server-connect`; listening on a TCP port is not yet supported |
| Editor support | Hover, completion, signature help, go to definition, document symbols, diagnostics |
| `--jvm` | Supported, with Java libraries through `--java-lib` (needs hxjava) |
| `--cs` | Type-checks against .NET assemblies given with `--net-lib`/`--net-std` (needs hxcs, like Haxe); no output is written yet, unless `-D dotnet` is set (see `--dotnet`) |
| `--dotnet <dir>` | Writes `<name>.dll` (plus `<name>.runtimeconfig.json` with `-main`) for .NET 10 or later, straight to IL with no C# step (needs hxcs, like `--cs` above). Early: classes (with reflection), interfaces, structs, generics, statics, strings, arrays, `Dynamic`, anonymous objects, `Null<T>`, enums, closures, `dynamic` methods, `Int64`, `Std`/`Type`/`Reflect`, generic instantiations and the casts between them, the Serializer, exceptions and calls into `--net-lib` assemblies (overloads, generic methods, `Nullable<T>`, indexers, properties, delegates) and a subset of inline C# work; see [.NET output](#net-output) |
| `--hl x.hl` | Early: HashLink bytecode, debug info included, byte-identical to Haxe 4.3.7's on the programs in `tests/cases/hl-output` (with `-D hl_no_opt`) and `tests/cases/hl-opt` (with the bytecode optimiser, Haxe's default, on); Haxe's unit suite (`compile-hl.hxml`, built against utest a94f881 as Haxe's CI does) gives a `unit.hl` identical to Haxe's apart from the compile-date string, checked with haxe-conformance's `corpus unit-hl`, which also requires both runs on hl.exe to match (measured: 0 errors, 0 failures); other large programs are not yet checked. HL/C (`--hl x.c`) writes the same files as Haxe 4.3.7, byte for byte, on those cases, on the `tests/cases/hlc-output` cases and on JoeClash's Android build (2800 files); it needs `-D no-compilation` unless the `hashlink` haxelib is installed, since without it the C build step ends in "Build failed" (see [tests/hl/README.md](tests/hl/README.md)) |
| `--lua`, `--python`, `--php`, `--neko`, `--swf` | Accepted on the command line; no output is written yet |

Prebuilt binaries are available for Windows x64, Linux x64 and macOS on Apple silicon.

## Install

### Download

Download `hxc-windows-x64.exe`, `hxc-linux-x64` or `hxc-macos-arm64` from the
[latest release](https://github.com/dimensionscape/hxc/releases/latest).

### From haxelib

```bash
haxelib install hxc
haxelib run hxc build.hxml
```

The first run downloads the release binary for your platform. hxc compiles against the standard
library of the Haxe you have installed.

To build hxc from the library's own source instead, for a platform without a release binary or to
use your own build, install the requirements under [Building from source](#building-from-source) and
run:

```bash
haxelib run hxc rebuild
```

`haxelib run hxc` then uses that build.

### The standard library

hxc uses the Haxe 4.3 standard library rather than shipping its own. If it is not found next to the
binary, point `HAXE_STD_PATH` at it:

```bash
export HAXE_STD_PATH=/path/to/haxe/std        # Windows: set HAXE_STD_PATH=C:\HaxeToolkit\haxe\std
```

## Usage

hxc accepts the same command line as `haxe`:

```bash
hxc -p src -m Main --js bin/main.js           # JavaScript
hxc -p src -m Main --cpp bin/cpp              # C++, built with hxcpp
hxc -p src -m Main --cppia bin/main.cppia     # cppia
hxc -p src -m Main --jvm bin/main.jar          # JVM bytecode
hxc -p src -m Main --dotnet bin/net           # .NET 10 assembly, bin/net/net.dll (early)
hxc -p src --run Main arg1 arg2               # run in the interpreter
hxc -p src -m Main --xml types.xml --no-output
hxc build.hxml
```

`hxc --help` prints the full option list. `hxc --version` reports `4.3.7`, the language version hxc
implements, so build tools that check the compiler version keep working.

### Compilation server

```bash
hxc --wait stdio
```

Requests arrive on stdin as length-prefixed blocks of arguments, and modules stay cached between
requests, so a warm rebuild of a small project returns in milliseconds. `--server-connect
host:port` connects out to a client that is listening instead.

### .NET output

`--dotnet <dir>` writes `<dir>/<name>.dll` straight as IL, with no C# step; `--cs <dir> -D dotnet` is the same build. Like `--cs`, it needs
hxcs (`haxelib install hxcs`): hxcs supplies the reference assemblies and the standard library's
runtime sources. With `-main` it also writes `<name>.runtimeconfig.json` for `net10.0`, so
`dotnet <name>.dll` runs the program on .NET 10; `-D dotnet-version=<N>` builds it for a later .NET
instead (a whole number, 10 or more, e.g. `-D dotnet-version=11` for `net11.0`). `-D dll-name=<name>`
sets the name; the default is the output directory's last segment. `-D dotnet-nullable=<package>[,...]`
writes the nullable metadata Roslyn writes for gencs's C# under `#nullable enable` for every type of the
modules of exactly those packages (not their sub-packages), so `NullabilityInfoContext` reads their
reference types as not null.

`-D dotnet-trim-root` embeds an `ILLink.Descriptors.xml` that keeps every member of the assembly when a
project publishes it with `PublishTrimmed`: the runtime's reflection reaches Haxe members by name, which
the trimmer can't see, so without it a fully trimmed program can lose them and fail at run time. It does
not keep members of .NET libraries that only dynamic access reaches (a `Dynamic` holding a `System.Uri`,
say). It is opt-in because `GetManifestResourceNames` lists the resource in an untrimmed run.

`-D dotnet-aot` also compiles the program to a native executable with Native AOT, `<dir>/<name>.exe`
(`<dir>/<name>` off Windows), for the machine's own OS and CPU; it can go in an `.hxml` like any define. It runs
`dotnet publish` on a project hxc writes to `<dir>/aot`, so it needs the .NET SDK and the C++ linker Native AOT
uses (on Windows, Visual Studio's C++ build tools), and the first build restores the compiler from NuGet. The
publish's report, warnings included, is in `<dir>/aot/publish.log` and the native debug symbols are in
`<dir>/aot/publish`. A program starts faster and uses less memory than under the JIT, but a long run can be slower.

Haxe's own reflection works as it does under the JIT, as the assembly's members are all kept. Members of .NET
libraries that only dynamic access reaches are not (a `Dynamic` holding a `System.Uri`, or `Type.createInstance` of
a framework class): they fail at run time unless `-D dotnet-aot-descriptor=<file>` names an
[ILLink descriptor](https://learn.microsoft.com/dotnet/core/deploying/trimming/trimming-options#root-descriptors)
that keeps them. `Sys.programPath()` returns an empty string. A `--net-lib` assembly that relies on run-time code
generation will not work, and a native library it loads still has to be beside the executable.

`-D dotnet-r2r` precompiles the assembly with ReadyToRun instead: `<dir>/<name>.dll` keeps its IL and gains machine
code for the machine's own OS and CPU, so it runs with `dotnet <name>.dll` and is referenced as before, and its PDB
still matches. It works for a library as well as a program, so of several assemblies some can be precompiled and
some not; `--net-lib` assemblies are left as they are. The program starts nearly as fast as a native one, and its
hot methods are still compiled again by the JIT, so a long run keeps the JIT's speed; on another OS or CPU the
runtime ignores the machine code and runs the IL. It runs `dotnet publish` on a project hxc writes to `<dir>/r2r`,
whose report is in `<dir>/r2r/publish.log`, so it needs the .NET SDK, and the first build restores Crossgen2 from
NuGet. It can't be used with `-D dotnet-aot`, or with `-D dotnet-debug-jit`, whose unoptimized code the precompiled
code would replace.

`-D dotnet-exe=launcher` adds an executable, `<dir>/<name>.exe` (`<dir>/<name>` off Windows), that starts
`<dir>/<name>.dll` beside it on the .NET installed on the machine, as `dotnet <name>.dll` does; it is about 160 KB.
`-D dotnet-exe=self-contained` makes it one file that holds the assembly, the `--net-lib` assemblies and the .NET
runtime, so it runs on a machine with no .NET installed, on its own (about 70 MB). Both are for the machine's own OS and
CPU, start at the program's entry point, and need `-main`. With `-D dotnet-r2r` the launcher starts the precompiled
assembly and the self-contained file holds it. Each runs `dotnet publish` on a project hxc writes to `<dir>/exe`, whose
report is in `<dir>/exe/publish.log`, so it needs the .NET SDK, and the first self-contained build restores the
runtime pack from NuGet. The self-contained file also holds the native libraries a `--net-lib` assembly has beside
it where a `dotnet build` leaves a NuGet package's, in `runtimes/<rid>/native` for the machine's OS and CPU or
`runtimes/<os>/native` (`win`, `linux`, `osx`), and unpacks them to a folder of the user's the first time it runs; a
launcher finds them as `dotnet <name>.dll` does, through a `<name>.deps.json` beside it. It can't be used with
`-D dotnet-aot`, whose native program is already an executable.

`-D dotnet-winexe` makes the `-D dotnet-exe` or `-D dotnet-aot` executable a Windows GUI program, so it opens no
console window; run from a console, what it prints still reaches that console's output. It changes nothing off Windows.

The assembly's references resolve against hxcs's `netlib` directory for `-D net-ver` (default 20), or
the directories given with `--net-std`. By default that means a reference to `mscorlib` 2.0.0.0,
which .NET 10 and later forward to their own libraries.

Code can use the assemblies given with `--net-lib`, as gencs's output does. A .NET type that a
`--net-lib` assembly uses but no supplied assembly defines, such as its base class or a framework type
in its signatures, is read from beside that assembly, then from the .NET reference pack:
`<dotnet root>/packs/Microsoft.NETCore.App.Ref/<newest N.0.x>/ref/netN.0` for the `-D dotnet-version` N
(default 10), where the dotnet root is `DOTNET_ROOT`, else the directory of `dotnet` on the `PATH`. So
the .NET SDK must be installed, not only the runtime; a pack that is needed and missing is a compile
error that names it. Those assemblies are used to write the output only: as in Haxe, Haxe code sees
only the assemblies passed, and a type defined only in one of them is "Type not found".

- **Calls** bind the .NET overload gencs's C# would bind, generic .NET methods included, or are a
  compile error. A hand-written extern (`@:native`) binds the overload C#'s compiler picks for its
  declared types and for its arguments' own types, which must agree, with omitted optional and `params`
  arguments filled as C# fills them. Its fields and properties are looked up from the receiver's type,
  as C# looks them up, so a derived class's `new` member hides the base's. Where two overloads apply,
  or hxc cannot tell whether one does, the call is a compile error rather than a guess, even where C#
  would pick the more specific one. So is a call where C# picks the overload by an integer constant's
  value, which C# also converts to a narrower integer type it fits and, if 0, to an enum (`B(5)` with
  `B(byte)` and `B(object)`); declare the parameter's exact type, or use `@:overload`. A `null`
  argument, or a left-out optional argument, which gencs passes as `null`, binds the overload C# picks
  for it: the one whose parameter at the null converts to the others' (`N(null)` with `N(Thing)` and
  `N(object)` is `N(Thing)`). Where C# finds none of them better, or hxc cannot tell which one it picks,
  the call is a compile error; pass a variable of the parameter's type, or use `@:overload`.
- **Value types:** `System.Nullable<T>` works, through `HasValue`, `Value`, `== null` and string
  concatenation. `null` passed or assigned where a .NET struct is expected is that struct's
  `default(T)`, as under gencs, so a `Nullable<DateTime>` built from a `null` `DateTime` has a value,
  `0001-01-01`. `x == null` is `!x.HasValue` on a `Nullable` and `x.Equals(default(T))` on another
  struct.
- **Indexers:** `a[i]` on a .NET type with an indexer calls it, compound assignment included. A Haxe
  class with an instance `__get` or `__set` gets gencs's indexer (`get_Item`/`set_Item`, an `Item`
  property and `[DefaultMember("Item")]`), so C# code can index it; `Array` has `T this[int]` and its
  companion interface's `object this[int]`, and a Haxe interface with `__get`/`__set` gets a default
  interface member indexer. A generic interface whose `__get` mentions no type parameter gets no `Item`
  property (only the CLR surface: Haxe itself rejects `i[x]` on an interface).
- **Inline C#:** `untyped __cs__(...)`, `cs.Syntax.code(...)` and `cs.Syntax.plainCode(...)` compile a
  subset of C# expressions with C#'s semantics: `{N}` placeholders, names (Haxe locals and members are
  resolved in the Haxe scope, as C# would see them, except in `plainCode`; types as CLR names over the
  referenced assemblies), member access, calls, indexers with any number of arguments (`cells[row, col]`),
  `new`, casts, `is`, `!`, `-`, arithmetic, comparisons, `&&`, `||` and literals, and a bare `throw`
  (below). Anything else (assignments, lambdas, statements, `typeof`, `as`, `?:`, `??` and the like) is a
  compile error naming the replacement, and so is C# in `@:classCode` or `@:functionCode`; the class is
  still compiled. A `@:classCode` of `#pragma` lines only is ignored. The replacements: hand-written
  `@:native` externs for what a `@:classCode` injected, and `#if !dotnet` around a `@:functionCode`. As
  under gencs, only code that survives DCE is checked.
- **Rethrow:** a bare `throw` in inline C#, `cs.Lib.rethrow(e)`, and `throw e` of a catch's own,
  never-assigned variable rethrow the caught exception with IL `rethrow`, keeping its stack trace
  (gencs's `throw e;` resets it). Outside a catch, in a local function or in a `finally`, a bare `throw`
  is a compile error, as in C#.
- **Properties:** a Haxe class implementing a .NET interface's properties (`var x(get, set)`) gives
  them CLR properties, so C# code reading them through the interface gets the Haxe getters' values.
  A `@:property` var is a CLR property too, so System.Text.Json and .NET reflection see it.
- **Delegates:** a Haxe function, lambda or method converts to a .NET delegate as gencs converts it,
  and a delegate's `+` and `-` combine and remove. A handler made again from the same method removes
  the first. `Thread.create` works. A conversion whose types do not match the delegate's `Invoke`
  (an `Int -> Bool` function as a `Func_2<Dynamic, Bool>`) is a compile error, as gencs's C# fails to
  compile there (CS0030) or its cast throws at run time.

Classes, interfaces, structs, generics, statics, operators, strings, arrays and native .NET
exceptions work, including `try`/`catch`/`throw` of `cs.system.Exception` subclasses. Classes have
the shape Haxe's own `--cs` generator gives them: they extend `haxe.lang.HxObject`, and fields and
methods can be reached by reflection (`Reflect.field`, `Reflect.setField`, `Reflect.callMethod`,
`Reflect.hasField` and the `Dynamic` field operations behind them). `Dynamic` works for field access,
calls, arithmetic, comparison, equality, string concatenation and conversion to and from the basic
types; reading an element of a `Dynamic` works, assigning one is not supported yet. Anonymous
objects (`{x: 1}`, printed and read through `Dynamic`) and `Null<T>`, including `Null<Int>`,
`Null<Float>` and `Null<Bool>` and defaulted arguments, work too.

Haxe enums become gencs's classes (`<pack>.<Enum>` and one `<pack>.<Enum>_<Ctor>` per constructor),
and `switch` on them works, also through an abstract over the enum or on a `Dynamic`. `switch` also
works on an `Int`, `Float`, `Bool` or `String`, on a `Class` or `Enum` value against types, and on a
`Dynamic` against constant patterns, which compare with `Runtime.eq` in case order as gencs's do.
Local functions and lambdas become gencs's closure classes (`<Class>_<field>_<line>__Fun`), method
closures are `haxe.lang.Closure`, and function values are called through `haxe.lang.Function`.
`dynamic` methods, `Int64` and `UInt64` arithmetic, `cs.Flags`, `Std`, `Type` and `Reflect` (enums
and classes alike), `haxe.Exception` with its stacks, and `haxe.Serializer`/`haxe.Unserializer`
work. Interface variables and `dynamic` methods of an interface are reached through
`haxe.lang.Runtime`, as gencs reaches them, and an interface method implemented with another return
type gets gencs's explicit implementation. The `@gencs` cases in the tests check that these behave
as gencs's output does, and `@serial` cases that serialized data round-trips between the two.

Generic classes are instantiated as gencs makes them. A type argument that is not a basic type (`Int`,
`Float`, `Bool`, `String`, `Int64` and the like) is erased to `object`, so `Box<Point>` is
``Box`1<object>``, and each generic Haxe class and interface gets gencs's companion interface
(`<pack>.<Class>`, with no arity), which `Std.isOfType` tests and `X<Dynamic>` is typed as: a typed
value passed where an `X<Dynamic>` is expected is the same object. A cast between two instantiations
(`Array<Dynamic>` to `Array<Int>`, `Map<String, Dynamic>` to `Map<String, Int>`) goes through gencs's
`X_cast` and `__hx_cast`, so maps and `List` are copied as gencs copies them, bugs included. `Type`,
`Reflect` and the Serializer see generic classes and their instantiations as gencs's do, so serialized
data with generic classes round-trips between the two. Two hxcs bugs are fixed on purpose. A cast to
a parent instantiation (a class to an `IMap<String, Int>` it implements, `FallbackPromise<T>` to
`Thenable<T>`) gives the right instantiation, where gencs's returns the object itself and the next cast
throws. And Haxe issue 8314 is fixed: casting an `Array<Dynamic>` to an `Array` of a basic type
(`Array<Int>`, `Array<Float>`, …) forwards the original to the typed array instead of copying it, so a
write through either one reaches both; a lossy cast (`1.5` into an `Array<Int>`) still copies.
`docs/superpowers/specs/2026-10-21-dotnet10-il-generator-design.md` lists these and the other recorded
divergences from gencs.

A class's or a generic method's type parameter that holds `Null<Int>`, `Null<Float>` or `Null<Bool>`
(an `Array<Null<Int>>`, a `Box<Null<Int>>`, `Lambda.exists` over an `Array<Null<Int>>`) reaches
`Dynamic`, reflection, string concatenation and the Serializer as gencs's boxed value or `null`. A
generic method's type parameters are bound as gencs binds them, by Haxe's unification of each
argument and the return (first) with the declared types. Where a declared `Null<T>` itself is an
argument or the return (`Lambda.find`'s `Null<T>` return, a `Null<T>` or optional argument, a
callback's return), T is bound to the basic type, so a null `Null<Int>` passed there becomes 0 as
it does under gencs. A `Null<T>` among a callback's arguments (`f:Null<T>->Bool`) keeps T a
`Null<Int>`, and so does one inside a type argument (`Array<Null<T>>`, `Option<Null<T>>`) met by a
`Null<Null<Int>>`. A local generic function's arguments bind the other way round, as gencs's closure
classes do.

Constructs not supported yet are compile errors in user code (`dotnet: ... not supported yet`). The
list is not complete; among others it has compound assignments to `Dynamic` array elements
(`d[i] += v`, `d[i]++`; a plain `d[i] = v` works), `return`, `break` and `continue` inside
expressions, casts between instantiations of a generic class that has no companion interface (a
generic `@:struct`) and `Std.isOfType` or enum constructor arguments with one,
a static `@:property` var with get or set accessors,
a .NET method, an overloaded method, a struct's method or a method reached through a `Dynamic`
receiver as a delegate, and a .NET base class's non-virtual method or property implementing an
interface method or property for a Haxe subclass (C# adds a forwarding stub there; a public virtual
one works), and the same for a Haxe superclass's event that implements an interface's event for a subclass
that lists the interface. An `@:event` var is a C# event (Haxe's own checks apply: private, both methods present, type
`T -> Void`): custom when the `add_` and `remove_` methods have bodies, field-like when both are empty (the
compiler's accessors over a private backing field, which only the class itself can read), and an interface
event for a Haxe interface's, which a class implements with an `@:event` var of its own, as it does a .NET
interface's. The var is no field, and reading or assigning a custom event's is an error, as in C#; so is a
field-like event's outside its class. Some of what gencs's C# refuses is refused too, with the C# error
(listed in the spec's *Interop divergences from gencs*). Milestones 4a
(referenced-assembly interop), 4b (inline C#, gencs's indexers, `IntPtr` members,
`CompilerGeneratedAttribute` on `@:property` vars) and 4c (attributes (`@:meta`, `@:strict`), nullability
metadata (`-D dotnet-nullable`), manifest resources, events, `@:nativeGen` details) are done, which is milestone 4:
the server app builds to its `HaxeServer.dll` with its resources, the C# projects that name Haxe types build
against it, its AI tool schemas are those of gencs's C# with the build script's four patches, and ILVerify of it against the deployed assemblies
prints nothing. A few constructs gencs's C# accepts stay compile errors, because nothing in the two apps uses
them: covariant-return `@:overload` overrides, two refinements of the overload rule in inline C#
(`Nullable<A>` to `Nullable<B>`, array covariance), `{0}[i]` on a program class in inline C# and `cs.Pointer.add`,
and so is a .NET member whose signature has a required modifier (`modreq`): a volatile field, the `in`
parameter of a virtual method, an init-only setter (the last fails in gencs's C# too, outside a subclass's
constructor). A .NET indexer accessor with a modreq is not refused yet, and fails when run.
A field-level `addMetadata` or `addTypePatch` aimed at a class the core types load before the init macros
run (`StringTools` on cs, `haxe.EnumTools`) is still missed, where Haxe 4.3.7 applies it; class-level
metadata, such as an added `@:build`, is applied, though a late patch aimed at an abstract reaches its impl
class only, not the abstract.
Embedded resources (`-resource` or `Context.addResource`) are manifest resources named `src.Resources.`
plus the name as `haxe.Resource` escapes it at run time, so `haxe.Resource` and C#'s
`GetManifestResourceStream` read them. A name with a non-ASCII character or a backslash is found, where
gencs's is listed but not found; two names that escape to one manifest name are a compile error.
hxc does not refuse a macro's access to the `cs` package, where Haxe's typer says "You cannot access the
cs package while in a macro".
Not run or not verified: the jvm path of `-resource` and `Context.addResource` never ran, and the order
`CppiaGen` writes resources in (`com.resources.keys()`) is unverified. On Windows hxc reads its command line in
the ANSI code page, so a non-ASCII `-resource` name, `-D` value or path is changed for every target, where
Haxe 4.3.7 reads UTF-16 (a front-end bug, not a .NET one).
Standard-library code that needs a construct not supported yet compiles to a stub: `cs.Pointer.add`
(the `+` operator on pointers) is the one left.

hxc ships its own copy of the hxcs runtime classes that generated code depends on
(`haxe.lang.HxObject`, `haxe.lang.DynamicObject`, `haxe.lang.FieldLookup`, `haxe.lang.Runtime`,
`haxe.lang.Null` and related). Messages name their source as `<hxc-dotnet-runtime>/`. They are used
in place of hxcs's versions, so a class path entry cannot override them.

The rest of the standard library comes from hxcs's runtime sources and is partly stubbed; a stubbed
method throws `System.NotSupportedException` when called. `-D dotnet-stub-report` prints what was
skipped, stubbed or ignored, one sorted line each; for a program that prints, maps an array and
throws and catches a `haxe.Exception` it prints nothing. A catch-all such as `catch (e:Dynamic)` or
`catch (e:cs.system.Exception)` catches a stub's exception too, so it can hide a stub.

The tests need the .NET 10 SDK and hxcs installed globally. They build `tests/fixtures/hxccheck`, compile each case twice to
check the output is deterministic, verify it with ILVerify, and run it:

```bash
tests/dotnet/run.sh --compiler path/to/hxc [--std path/to/haxe/std] [--case name] [--haxe path/to/haxe] [-j jobs] [--no-gencs-cache]
```

Cases run 8 at a time (`-j` or `HXC_TEST_JOBS` changes that; `-j 1` runs them one by one, in order), and their
reports print in case order. Cases tagged `@stress-…` or `@run-timeout`, whose results depend on timing, run alone after
the rest.

Cases tagged `@gencs` are also compiled with Haxe 4.3.7's own `--cs` generator (`-D no-compilation`), the C# is built
for net10.0, and its output must match the hxc build's. That needs Haxe 4.3.7 (`haxe`, or `--haxe`) with hxcs on the
haxelib path, and a case directory path without spaces, since hxcs fails on them (`HXC_TEST_TMP` sets the directory).
Cases tagged `@serial` are `@gencs` cases that also round-trip `haxe.Serializer` data between the two builds: the
program writes `name<TAB>serialized` lines with `gen <file>` and reads them back with `rt <in> <file>`, and hxc's build
reading gencs's data, gencs's build reading hxc's data and hxc's build reading its own data must all print what gencs's
build prints when it reads its own. `serial-corpus` covers the Serializer's encodings and hxcs's quirks this way.
gencs's results (and, for `@serial` cases, its build and data) are cached in `tests/dotnet/tmp/gencs-cache` (under
`HXC_TEST_TMP`), keyed by the case, `gencs.csproj.in`, the script's gencs steps, Haxe, its std, the global hxcs, the .NET
SDK and the time zone, so only changed cases go through gencs again; `--no-gencs-cache` skips the cache.
Each run of a test program stops after 120 seconds (`HXC_RUN_TIMEOUT` changes the limit, and a case's
`@run-timeout=<seconds>` tag changes it for that case), which fails its case.

### Debugging .NET output

`-debug` with `-D dotnet` also writes `<name>.pdb`, a Portable PDB, beside the DLL, and the DLL's debug
directory names it. The PDB holds a sequence point per Haxe statement, with the `.hx` file and line, the
Haxe names of the locals, and the text of hxc's own runtime files, so exception stack traces
(`Exception.ToString()`, `haxe.CallStack`, `haxe.Exception.details()`) name the `.hx` file and line of
each Haxe frame. Without `-debug` there is no PDB, and the DLL is the same as before.

How Visual Studio and VS Code's C# debugger (`coreclr`) use the PDB (binding breakpoints, stepping, the
Locals and Watch windows, finding the source files) is still being checked by hand, with
`docs/superpowers/plans/2026-10-29-dotnet-portable-pdb/debugger-checklist.md`; the setup below is what
that checklist tries.

A released build can ship its `.pdb` beside its `.dll`, so that the exception stack traces in its logs
carry `.hx` lines. That build needs only `-debug`, and no `-D dotnet-debug-jit`: it keeps the JIT's
optimizations, and the lines it reports are the JIT's usual approximation for an optimized method.

For a debugger, also pass `-D dotnet-debug-jit`. It adds a `DebuggableAttribute` that turns the JIT's
optimizations off, which a debugger needs to stop on every line and show every local. A local has its Haxe
name in the PDB. Inside a closure's body, a variable it captured is a field of the closure's object, not a
named local; the function that declared it still names its own copy.
`-D dotnet-debug-jit` needs `-debug`, and is a compile error without it.

A `-D dotnet-debug-jit` build is for debugging on the machine that built it, so its PDB names each source
file by full path, and a debugger opens them with no setup: VS Code binds a breakpoint to a short name too,
then cannot open the file (`Could not load source 'src/data/Puzzles.hx': Incorrect format of 'source' message.`).
Any other PDB names files by short paths, so it does not hold the build machine's folders. The first of
these rules that fits gives the name, written with forward slashes:

1. `-D dotnet-pathmap=<from>=<to>[,<from>=<to>...]`: a file whose full path starts with `<from>` gets
   `<to>` in its place. The longest `<from>` wins, and a relative `<from>` is resolved against the
   current folder. A value that is not `<from>=<to>` pairs is a compile error: `-D dotnet-pathmap must be
   <from>=<to> pairs separated by commas, like C:/work/=src/ (not <the value>)`.
2. hxc's own runtime files: `hxc-runtime/` plus the path. Those files exist only inside the hxc binary,
   so their text is embedded in the PDB, and there is no folder to map for them.
3. In a `-D dotnet-debug-jit` build, anything else: its full path.
4. A file under the current folder (where hxc runs, or `--cwd`): its path relative to that folder, such
   as `src/db/Foo.hx`.
5. A file under the Haxe std: `haxe-std/` plus the path under it, such as `haxe-std/haxe/Exception.hx`
   (the overlays under `cs/_std/` keep that folder).
6. A file of a haxelib library: `haxelib/<library>/` plus the path under the library's class path.
7. Anything else: its full path, with a warning that names `-D dotnet-pathmap`.

To debug a build with short names, the debugger has to be told where those folders are. In VS Code, add a
`sourceFileMap` to the `coreclr` launch configuration, and let `symbolOptions` find the `.pdb`:

```json
{
	"type": "coreclr",
	"request": "launch",
	"program": "${workspaceFolder}/out/out.dll",
	"justMyCode": false,
	"symbolOptions": { "searchPaths": ["${workspaceFolder}/out"] },
	"sourceFileMap": {
		"src/": "${workspaceFolder}/src/",
		"haxe-std/": "C:/HaxeToolkit/haxe/std/"
	}
}
```

`haxelib/<library>/` can be mapped the same way, to the library's class path. In Visual Studio, the
folders go under the solution's Properties > Common Properties > Debug Source Files: the folder that
`src/...` is relative to, and the Haxe `std/` folder itself (a `haxe-std/haxe/Exception.hx` document is
expected to be found as `haxe/Exception.hx` under it), or a file can be pointed at with "Find source" in
the Call Stack window. `tests/dotnet/debugger` holds a small program with a ready `launch.json` to try this on, and
`build.hxml` there builds it.

## Building from source

Requirements:

- [Haxe](https://haxe.org) 4.3, which includes Neko
- hxcpp from [openfl/libhxcpp](https://github.com/openfl/libhxcpp), branch `main`
- [Aedifex](https://github.com/DimensionscapeOrg/aedifex) 1.0.0-rc.3 or later
- A 64-bit C++ toolchain: MSVC on Windows, GCC or Clang on Linux, the Xcode command-line tools on macOS

```bash
haxelib git hxcpp https://github.com/openfl/libhxcpp.git main
cd "$(haxelib libpath hxcpp)/tools/hxcpp" && haxe compile.hxml && cd -
haxelib install aedifex 1.0.0-rc.3
git clone --recursive https://github.com/dimensionscape/hxc.git
cd hxc
haxelib run aedifex build cpp .
```

The second line builds hxcpp's command-line tool, which a git checkout of hxcpp does not include.

The compiler lands in `bin/cpp/<platform>/<arch>/release/bin/`. hxc builds with the `haxe` on your
`PATH`; to build hxc with hxc, set `AEDIFEX_HAXE` to an hxc binary.

hxc needs the hxcpp fork: the hxcpp release on haxelib predates files hxc's build uses, and later
hxcpp releases have a garbage collector regression that large hxc compiles run into.

## hxia

hxia is a sandboxed runtime for loading Haxe modules into a shipped application, for modding,
plugins and live content. A module is compiled once to a cppia artifact and can then be loaded by
both the native and the web build of the same program.

The sandbox starts at compile time. A module is compiled against a profile, and anything outside
it is rejected before the artifact exists:

```bash
hxc -p mods -m Greeter --cppia greeter.cppia --hxia core
```

```
mods/Sneaky.hx:1: characters 59-69 : hxia: 'sys.io.File.getContent' requires capability 'fs.read'
under profile 'core' (grant it with --require fs.read)
```

At run time the host decides what a module can see and how much it may spend:

```haxe
var host = hxia.Host.build()
	.profile(Core)
	.exposeStd()
	.expose(GameApi)
	.build();

var runtime = new hxia.Runtime(host, {fuelPerCall: 100000, maxCallDepth: 256});
var mod = runtime.loadFile("mods/greeter.cppia");
mod.boot();

var greeter = mod.make("Greeter", []);
trace(mod.call(greeter, "greet", ["world"]));
```

Every module loads into its own namespace, so two modules can define the same class without
colliding, and a reload is simply a fresh load. Capabilities are scoped (`FsRead(prefix)`,
`NetClient(hostPattern)` and so on), artifacts can be pinned by hash, and calls are metered for
fuel, call depth and allocation.

## Repository layout

| Path | Contents |
| --- | --- |
| `src/hxc/ast`, `parser` | Syntax tree, lexer, parser, preprocessor, reification |
| `src/hxc/core`, `typing` | Type model, unification and the typer |
| `src/hxc/context` | Compilation context, module loading, server cache, display |
| `src/hxc/eval` | The macro interpreter and its native bindings (libuv, mbedTLS, PCRE2) |
| `src/hxc/filters`, `optimization` | Post-typing filters, DCE, inlining, the analyzer |
| `src/hxc/generators`, `codegen` | JavaScript, C++ and cppia generators; XML and JSON output |
| `src/hxc/compiler` | Command line, messages, display output |
| `src/hxia` | The hxia runtime, linker, host API and `hxia` command-line tool |
| `thirdparty/libuv` | libuv, as a git submodule |

## Reporting bugs

A difference from Haxe 4.3.7 on a supported target is a bug. Please open an issue with the `.hxml`
or command line, the source, and the output of both compilers.

## License

hxc is licensed under the [Mozilla Public License 2.0](LICENSE). libuv, under `thirdparty/libuv`,
keeps its own license.

Haxe is a project of the Haxe Foundation. hxc is an independent project and is not affiliated with it.
