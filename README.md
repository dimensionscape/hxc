# hxc

**A Haxe 4+ compiler written in Haxe.**

hxc is a from-the-ground-up implementation of the Haxe compiler in Haxe itself. It parses,
types and generates code for real Haxe projects, runs macros in its own eval interpreter,
and speaks the compilation-server and display protocols that editors rely on. It is
self-hosting: hxc can compile its own source into a working compiler.

hxc is the precursor compiler for **hx+**.

## Highlights

- **Full front end** - lexer, preprocessor, parser and reification, plus the typer, type
  unification, abstracts, `@:multiType`, static extensions and the rest of the Haxe 4 type system.
- **Macros** - an eval interpreter for the macro world, with init macros, build macros,
  expression macros and the `haxe.macro` APIs, backed by libuv, mbedTLS and PCRE2 for the
  `sys` side of the standard library.
- **Code generation** - JavaScript and C++ generators, `--xml` type descriptions, and
  `--interp` / `--run` for running programs directly in the interpreter.
- **Compilation server** - `--wait` with per-context module caching, a reusable macro world,
  and warm-request telemetry.
- **Editor support** - hover, completion (toplevel, fields, type headers, JSON fields),
  signature help, go to definition, document symbols and diagnostics.
- **hxia** - a sandboxed cppia runtime and tooling for loading Haxe modules into a host
  application, each in its own namespace with fuel, call-depth and allocation limits.

## Building

Requirements:

- [Haxe](https://haxe.org) 4 and [hxcpp](https://github.com/HaxeFoundation/hxcpp)
- The Aedifex build tool (`haxelib run aedifex`)
- A C++ toolchain (MSVC on Windows), 64-bit

libuv comes in as a git submodule, so clone with `--recursive`:

```bash
git clone --recursive https://github.com/dimensionscape/hxc.git
cd hxc
haxelib run aedifex build cpp .
```

In a checkout made without it, run `git submodule update --init` first. GitHub's "Download ZIP"
leaves submodules out, so build from a clone.

The executable lands in `bin/`. Once you have an hxc build, it can rebuild itself in place of
`haxe`. Build settings live in [`Aedifex.hx`](Aedifex.hx), including the 64-bit, large-block GC configuration the compiler needs for big jobs.

## Usage

hxc accepts the same command line as `haxe`:

```bash
hxc -p src -m Main --js out/main.js
hxc -p src -m Main --cpp out/cpp
hxc -p src --run Main arg1 arg2
hxc --wait stdio
```

Run `hxc --help` for the full list of options.

## Repository layout

| Path | Contents |
| --- | --- |
| `src/hxc/ast`, `parser` | Syntax tree, lexer, parser, preprocessor, reification |
| `src/hxc/core`, `typing` | Type model, unification and the typer |
| `src/hxc/context` | Compilation context, module loading, server cache, display |
| `src/hxc/eval` | Macro interpreter and its native bindings |
| `src/hxc/filters`, `optimization` | Post-typing filters, DCE, inlining and analysis |
| `src/hxc/generators`, `codegen` | JavaScript, C++ and XML output |
| `src/hxc/compiler` | Command line, messages, display output |
| `src/hxia` | Embeddable cppia runtime, linker and `hxia` CLI |
| `thirdparty/libuv` | [libuv](https://github.com/libuv/libuv) v1.48.0, as a git submodule |

## Status

hxc is under active development. Its goal is output and behaviour that match the reference
Haxe compiler, verified against the Haxe unit test suite and real-world projects. Expect rough
edges on targets beyond JavaScript and C++.

## License

hxc is licensed under the [Mozilla Public License 2.0](LICENSE).
libuv, under `thirdparty/libuv`, keeps its own license (MIT).
