# HashLink target tests

## Unit suite

`tools/hl-unit.sh` and `corpus unit-hl` (haxe-conformance) build Haxe's own `tests/unit/compile-hl.hxml` with
Haxe and with hxc. The two `unit.hl` files match but for the compile date. Run on `hl.exe` 2.0.0, both end the
same way: after `START` and about 0.6 s, `Uncaught exception: Null access`, called from
`utest.ui.text.PrintReport._trace` (PrintReport.hx:52), because `haxe.Log.trace` is null by then. It happens
with Haxe's own `unit.hl`, so it is not an hxc problem.

### Which test leaves `haxe.Log.trace` null, and why

`tests/unit/src/unitstd/haxe/Log.unit.hx` (compiled to `unit.spec.haxe.TestLog.test`) sets
`haxe.Log.trace = null`, calls `exc(function() trace("exc test"))`, and restores `haxe.Log.trace = old` on the
next line. The restore never runs:

- `unit.Test.exc` is `Assert.raises(f, pos)`, but `Assert.raises(method, ?type:Any, ?msgNotThrown, ?msgWrongType, ?pos)`
  takes the type second. So the PosInfos object is passed as `type`.
- `_raisesImpl` starts with `type != null ? "exception of type " + Type.getClassName(type) : ...`, before its
  `try`. On HashLink `Type.getClassName` of an anonymous object throws `Can't cast dynobj to hl.Class`. Other
  targets return null there.
- So every `exc(...)` call throws out of the test body. utest records it as an error (20 of them in the whole
  suite) and carries on with the next test. For TestLog this skips the restore, and the final report's
  `haxe.Log.trace(s)` is a call of null.

Found with Haxe 4.3.7's own build, by replacing `Log.unit.hx` in a copy of tests/unit with `Sys.println` probes:
`trace` was non-null after the first restore and null after `C set null`; a direct `try { trace("x") } catch`
caught the null access fine, `Assert.raises(function() trace(...))` returned normally, and `exc(...)` threw
`Can't cast dynobj to hl.Class`. Ruled out: `-D hl-ver=1.13.0`, the null call itself (it is caught), and
other tests assigning `haxe.Log.trace` (only TestMain's JS branch and Log.unit.hx do).

Compiling with a copy of `unit/Test.hx` that has `Assert.raises(f, null, null, null, pos)` first on the
class path (`-cp <dir>`; tests/ untouched) gives, with Haxe, `assertations: 10975, successes: 10975,
errors: 0, failures: 0` and `ALL TESTS OK`.

haxe-conformance's `corpus unit-hl` now does that for both compilers (branch hl-unit, aec50e4), prints
each run's error and failure counts, and ignores the `execution time:` line when comparing the runs.
