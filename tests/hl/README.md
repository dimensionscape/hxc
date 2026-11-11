# HashLink target tests

## Unit suite

`tools/hl-unit.sh` and `corpus unit-hl` (haxe-conformance) build Haxe's own `tests/unit/compile-hl.hxml` with
Haxe and with hxc. The two `unit.hl` files match but for the compile date.

`corpus unit-hl` builds against utest `a94f881`, the pin in Haxe 4.3.7's CI. On `hl.exe` 2.0.0 both runs end in
utest's success summary (ALL TESTS OK, 0 errors, 0 failures).

Only `tools/hl-unit.sh`, which builds against the installed utest (`a055e05`, UTest 2), still shows a crash. On
`hl.exe` 2.0.0 both runs end, after `START` and about 0.6 s, in `Uncaught exception: Null access`, called from
`utest.ui.text.PrintReport._trace` (PrintReport.hx:52), because `haxe.Log.trace` is null by then. It happens
with Haxe's own `unit.hl`, so it is not an hxc problem; the next section says why.

### Why `haxe.Log.trace` is null

`tests/unit/src/unitstd/haxe/Log.unit.hx` (compiled to `unit.spec.haxe.TestLog.test`) sets
`haxe.Log.trace = null`, calls `exc(function() trace("exc test"))`, and restores it on the next line. The
restore never runs, because `unit.Test.exc` is `Assert.raises(f, pos)` and that call throws out of the test:

- The suite expects utest `a94f881`, the pin in Haxe 4.3.7's CI (`tests/RunCi.hx`). There
  `raises(method, ?type:Class<Dynamic>, ...)`, so a PosInfos argument skips `type` and binds to `pos`.
- The installed utest (`a055e05`, 2.0.0-alpha) is UTest 2, where `type` is `Any`. `pos` lands in `type`, and
  `_raisesImpl`'s `Type.getClassName(type)`, before its `try`, throws `Can't cast dynobj to hl.Class` on
  HashLink. That throw is a symptom, not the cause.
- Every `exc(...)` call then aborts its test: utest records 20 errors and carries on. For TestLog the skipped
  restore leaves `haxe.Log.trace` null, so the final report's `haxe.Log.trace(s)` is a call of null.

It happens with Haxe's own `unit.hl`, so it is not an hxc problem. Found with Haxe's build by replacing
`Log.unit.hx` in a copy of tests/unit with `Sys.println` probes. Ruled out: `-D hl-ver=1.13.0`, and the null
call itself (it is caught).

With utest `a94f881` the suite runs to its summary: 0 errors, 0 failures, `ALL TESTS OK`, for Haxe and for hxc.
haxe-conformance's `corpus unit-hl` builds both compilers against that commit (exported from the installed
utest's git checkout into a cache, selected with `HAXELIB_PATH`), prints each run's error and failure counts,
and ignores the `execution time:` line when comparing the runs.

## JoeClash (M5)

JoeClash, a Heaps game with hxsl shaders and HaxeUI, is the large program the HashLink target is checked on.
Built from the same source and hxml, hxc's `game.hl` is byte-identical to Haxe 4.3.7's in three builds:

- `build.hxml` (the desktop game, optimiser on);
- the same with `-D hl_no_opt`;
- `build.drive.hxml` (the same game plus the heaps-drive control channel).

Give hxc `HAXE_STD_PATH` spelled with backslashes, as Haxe's default is, or the debug file names differ.

hxc's driven build passes the game's smoke run on `hl.exe` 2.0.0 (`tools/drive-smoke.mjs`): a move, an end
of turn and the enemy's turn, a turn to landscape and a tap, with an empty `app.err`. Checked 2026-11-10 at
`5f21bea7`.

## HL/C (M6)

`--hl out/main.c` writes the files Haxe 4.3.7 writes (hxc ports hl2c.ml): main.c (named after the `--hl`
file) and hlc.json at the top; each module's .h and .c under its package path (`_std/` for the top-level
package, `haxe/`, `hl/types/`, ...); and in hl/ the shared natives.h, globals.c, types.c, reflect.c,
functions.c, hashes.c and init.c, with hl/ctx/<digest>.h for a closure context several modules share and
hl/bytes_<md5>.h for a large bytes constant. hlc.h and hlc_main.c are not written: they come with HashLink.

Both compilers are given `-D no-compilation`, since without the `hashlink` haxelib the C build step after
the files are written ends in "Build failed". hxc's files are byte-identical to Haxe's on:

- the hl-output and hl-opt cases, run with `tests/hl/run.sh --hlc`;
- the hlc-output family (18 cases), whose family.json names `out/main.c`, so it runs in this mode without
  `--hlc`; the cases cover string constants, naming, modules, closures, enums, virtuals and the other
  things hl2c.ml hashes or orders;
- JoeClash's Android build (2800 files).

In this mode (directory mode) `run.sh` has Haxe, hxc and hxc again each write an `out/` directory, kept as
`h/`, `x/` and `y/` in the case's folder. It compares them with `diff -r -q`; hl is not run. The two hxc
runs must agree, and the `-D dump` check applies as before.

`tools/hlc-compare.sh <h dir> <x dir>` explains a difference: the files only one side has, then the first
differing file with 40 lines of `diff -u`. With `--list` it prints every file that differs or is missing on
one side, one per line.

`tools/hlc-joeclash.sh <hxc exe> <scratch dir>` builds the first section of JoeClash's `build.android.hxml`
with Haxe, hxc and Haxe again, with `--hl` pointed into the scratch dir and `-D no-compilation` added, and
compares them. Files where the two Haxe builds differ are Haxe's own nondeterminism; they are listed and
left out. It prints `files: <n> identical` on a match. It writes its output into the scratch dir and checks
three things about JoeClash's folder: the section as built names no `bin/`, `git status --short` is the same
before and after, and no file under bin/android is newer than the start.

Not covered yet:

- 7-character type-digest collisions: no case reaches one, so the collision handling is untested.
- A class proto's maps, which HlcOcaml leaves unmodelled: a hash or marshal that reaches one throws
  `Unmodelled`, and hxc stops with "HL/C: hl2c's type digest reaches an OCaml value hxc does not model". A
  virtual proto's vindex map is modelled. A type description marshals a whole ttype only under HRef (and
  HNull, which holds no proto), so `hl.Ref` of a class (`static function f(r:hl.Ref<C>)`) stops this way.
  `hl.Ref` of an enum or an anonymous type is modelled but no case covers it.
- Name strings shared other than through a class field or its copies: a vfield's name is shared when its
  class fields have one nameOrigin (TClassField.nameOrigin: the field itself, or the field a copy was made
  from), so an interface's inherited fields and the `{cf with ...}` copies of apply_params, structure
  extension and map_anon_ref share. Haxe also shares a name a macro takes out of a field and builds a new
  field from (decode_string returns the same string), a string literal or variable a macro uses as the
  name of fields it builds on separate calls (one string in the macro's code; for example, two typedefs
  built by one `onTypeNotFound` macro, both as arguments of one function), and the name of an object
  declaration typed twice; hxc gives such fields names of their own, so those type names differ from Haxe's.
