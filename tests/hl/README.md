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
- the hlc-output family (32 cases), whose family.json names `out/main.c`, so it runs in this mode without
  `--hlc`; the cases cover string constants, naming, modules, closures, enums, virtuals and the other
  things hl2c.ml hashes or orders. hlc-digest-collision and hlc-digest-collision-reversed declare two
  function types whose digests share their first 7 digits, in both orders, so each side once keeps
  t$fun_f8d4f18 and once gets the full digest; the first also signs a function type twice through
  `hl.Ref<Float->Bool>`. hlc-ref-enum takes `hl.Ref` of enums, whose digests marshal enum protos whole.
  The hlc-macro-* cases give fields names from a macro, which Haxe's eval hands over as the very OCaml
  string the macro holds: a string literal used on two calls, from a variable or from an inline function
  (literal, variable, inline), a field's name taken by Context.getType or Context.getBuildFields (field,
  build-field, object-field), names in class fields a build macro adds (interface), in object
  declarations a macro returns (object, object-twice) and in one it types and turns back into syntax with
  Context.typeExpr and Context.getTypedExpr (typed-object); hlc-macro-separate-names is the control;
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

- A type digest that reaches a PMap: `hl.Ref` of a class (`static function f(r:hl.Ref<C>)`), of an
  anonymous type, or of an enum one of whose constructors takes a class or an anonymous type (an argument
  of type String counts: String is a class, so its proto and maps are marshalled too). A type
  description marshals a whole ttype only under HRef (and HNull, which holds no proto), and every class
  proto holds three PMaps (pindex, pfunctions, pinterfaces) and every virtual one (vindex). A PMap holds
  its `compare` closure, which `Marshal.Closures` writes as code pointers with the MD5 of haxe.exe's OCaml
  code as it is in memory. That code holds absolute addresses (`movabs` of C functions such as
  caml_compare) which Windows relocates to wherever it loads haxe.exe, so Haxe's own name for such a type
  changes with the load address. haxe.exe's name is stable only while its load address is, that is per
  boot, and a copy of haxe.exe elsewhere names such types differently: a byte-identical copy names
  `(ref(C)):void` t$fun_9e384e2 where haxe.exe names it t$fun_02c4ee9, and the copy's name changes from
  one run to the next. That is also why no hlc-output case covers them. HlcOcaml models the rest (the
  protos, their maps as genhl fills them, the sharing of names and of PMap.empty, and the closure's layout
  in Haxe 4.3.7's Windows haxe.exe) and matches Haxe on
  a class, a superclass, a graph of classes, methods, overrides, interfaces, toString, dynamic methods,
  std classes, an enum with a String and an anonymous type, with and without hl_no_opt, when given the MD5
  measured for the address haxe.exe was loaded at (HlcCheck keeps two such vectors). Without it hxc stops
  with "HL/C: hl2c's type digest reaches the compare closure of a PMap, ...".
- Name strings shared in ways hxc does not track. A vfield's name is shared when its class fields have one
  nameOrigin (TClassField.nameOrigin): the field itself, the field a `{cf with ...}` copy was made from
  (an interface's inherited fields, apply_params, structure extension, map_anon_ref), the parsed field or
  object field it was typed from (Ast.fieldNameOrigin), or what the macro string that named it stands for
  (EvalMacro.nameOriginOf: a string literal's TString, or the field or object field the macro API encoded
  the name from, as eval's encode_string and decode_string pass the OCaml string through), through a typed
  object declaration's key (TexprTools.objectKeyNameOrigin) as well. Haxe also
  shares a name in a macro string that eval takes from elsewhere without copying, such as its field-name
  hash table (`Reflect.fields`, whose names are the strings first hashed), and a string literal typed twice
  (one AST string, where hxc makes a TString per typing); hxc gives such names strings of their own, so
  those type names differ.
