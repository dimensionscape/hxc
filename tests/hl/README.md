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
