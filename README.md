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
| `--cpp`, `--cppia` | Supported, using hxcpp to build |
| `--interp`, `--run` | Supported |
| `--xml`, `--json` type descriptions | Supported |
| Compilation server | `--wait stdio` and `--server-connect`; listening on a TCP port is not yet supported |
| Editor support | Hover, completion, signature help, go to definition, document symbols, diagnostics |
| `--jvm` | In progress |
| `--lua`, `--python`, `--php`, `--hl`, `--cs`, `--neko`, `--swf` | Accepted on the command line; no output is written yet |

Prebuilt binaries are available for Windows x64. Linux x64 builds from source; macOS is in progress.

## Install

### Download

Download `hxc-windows-x64.exe` from the [latest release](https://github.com/dimensionscape/hxc/releases/latest).

### From haxelib

```bash
haxelib install hxc
haxelib run hxc build.hxml
```

The first run downloads the release binary for your platform. hxc compiles against the standard
library of the Haxe you have installed.

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

## Building from source

Requirements:

- [Haxe](https://haxe.org) 4.3, which includes Neko
- hxcpp from [dimensionscape/hxcpp](https://github.com/dimensionscape/hxcpp), branch `production`
- [Aedifex](https://github.com/DimensionscapeOrg/aedifex)
- A 64-bit C++ toolchain: MSVC on Windows, GCC or Clang on Linux

```bash
haxelib git hxcpp https://github.com/dimensionscape/hxcpp.git production
haxelib git aedifex https://github.com/DimensionscapeOrg/aedifex.git
git clone --recursive https://github.com/dimensionscape/hxc.git
cd hxc
haxelib run aedifex build cpp .
```

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
