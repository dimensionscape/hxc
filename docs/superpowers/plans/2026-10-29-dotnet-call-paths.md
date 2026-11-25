# .NET faster call paths: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `Array.map`/`filter`, Haxe methods used as values, and `Reflect.field`-style calls faster in hxc's `-D dotnet` output, with no change in what programs print.

**Architecture:** `map`/`filter` become `inline` in the runtime `Array`, with a typer rule that leaves `Array<Dynamic>` receivers and results on today's call. `haxe.lang.Closure` gains an optional `ClosureInvoker`, and `ClosuresToClass` generates one invoker class per eligible method used as a value, which checks argument types and calls the method directly, or lets `Closure` go by name as today. `TexprDynamic` picks Runtime's `HxObject` overloads for Haxe-class receivers.

**Tech Stack:** Haxe (hxc, built with hxcpp), .NET 10 IL, bash harness `tests/dotnet/run.sh` (cases in `tests/dotnet/cases.hx.txt`), Haxe 4.3.7 gencs as the `@gencs` reference.

**Spec:** `docs/superpowers/specs/2026-10-29-dotnet-call-paths-design.md`. It extends `docs/superpowers/specs/2026-10-21-dotnet10-il-generator-design.md` (the main spec) and `2026-10-29-dotnet-portable-pdb-design.md`.

## Global Constraints

- **Work in a worktree.** Another session has uncommitted work in `D:/_github/hxc` and rebuilds its `hxc.exe`. Create `git worktree add D:/_github/hxc-callpaths -b dotnet-il-callpaths dotnet-il-m5`, copy the gitignored `.haxelib` folder into it, and build and test only there. Never edit, build or commit in `D:/_github/hxc`.
- Case names, case text, commit messages and repo docs never name the private apps, their classes, paths or email. Say "the server app" / "the desktop app".
- Never push or merge. Every commit message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Build (from the worktree): `AEDIFEX_ROOT=D:/_github/hxc-toolchain/aedifex/ HAXE_STD_PATH=C:/HaxeToolkit/haxe/std HXCPP_COMPILE_CACHE=D:/_github/hxc-toolchain/hxcpp-cache haxelib run aedifex build cpp .` → `bin/cpp/windows/x64/release/bin/hxc.exe` (`HXC` below). hxc's runtime is embedded in the exe, so rebuild after editing it.
- One case: `bash tests/dotnet/run.sh --compiler $HXC --std C:/HaxeToolkit/haxe/std --case <name>`. ALL: the same without `--case`, 607 cases at the branch point; every one keeps passing unedited, except where a task says so.
- Own suite: `cd D:/_github/haxe-conformance && neko run.n run --compiler $HXC --std C:/HaxeToolkit/haxe/std --cases <worktree>/tests/cases --expected <worktree>/tests/expected`.
- IL inspection: `dotnet D:/_github/hxc/.superpowers/research/hxc5-perf/ildump/bin/ildump.dll <dll> [type-substring] [method]` (`ILDUMP`). A case's DLL is at `tests/dotnet/tmp/.../a/P/P.dll`; or compile a probe by hand: `HAXE_STD_PATH=C:/HaxeToolkit/haxe/std $HXC --cwd <dir> -cp . -main P --cs a/P --haxelib-global -D dotnet`.
- No output change: same prints as today and as gencs, serialized data unchanged, DLL and PDB deterministic, ILVerify clean. The one accepted difference: when a method value throws, frames that are not the program's own Haxe frames may differ.
- Applies with and without `-debug`. Generated statements use `Position.nullPos` under `-debug`, as `ClosuresToClass.invokeMethod`'s `unpackPos` does.
- Match the surrounding code: hxc's naming, comment density and idiom.

**Plan rulings on what the spec leaves open:**
- A. Metadata name: `@:inlineUnlessDynamic`. It also stops the inline when the call's result is `Array<Dynamic>` (`pts.map(p -> Reflect.field(p, "x"))`): the inlined `ret` would be the companion, reached by name for every element, the same cost the receiver rule avoids.
- B. Invoker entry points cover 0–5 arguments. Call sites send 6 or more to `__hx_invokeDynamic` (`TexprCalls.invokeFunction`), which stays by name, so a 6-argument method is by-name.
- C. Direct shapes are the table in Task 3. Anything else stays by name.
- D. `localFieldCall` (a place read and written more than once) keeps `LObject`: its receiver is already in an object local. Only `fieldGet`, `fieldSet`, `fieldCall` change.

## Review Focus

1. **A receiver typed `Array<Dynamic>`, holding a plain or a typed array, or a callback returning `Dynamic`:** behaves and performs as today, no per-element by-name calls. Test in Task 1 (`array-map-dynamic-not-inlined`, `array-map-dynamic-result`, plus the existing `companion-array-map-filter`).
2. **A callback that mutates the array it is mapping** (push past capacity, `shift`, write ahead): sees what gencs's inlined loop sees. Test in Task 1 (`array-map-filter-mutating`).
3. **`-D no-inline`:** `map` and `filter` still work as ordinary methods with the same results. Test in Task 1 (`array-map-no-inline`).
4. **A null receiver:** an array, or an instance whose method is read as a value, gives the same error at the same moment as today and gencs. Tests in Task 1 (`array-map-filter-inlined`) and Task 4 (`method-value-null-receiver`).
5. **Static initialization order:** reading `P.inc` as a value must not run `P`'s static initializer sooner than today. Test in Task 3 (`method-value-static-init`).

---

### Task 1: Inline `map` and `filter`, except on `Array<Dynamic>`

**Files:**
- Modify: `src/hxc/typing/Inline.hx` (`tryInline`, in the `Method(MethInline)` branch's vicinity, about line 76-94)
- Modify: `src/hxc/codegen/dotnet/runtime/Array.hx:632-639, 660-670`
- Modify: `docs/superpowers/specs/2026-10-21-dotnet10-il-generator-design.md:1145-1147` (the closure-class count bullet)
- Modify: `docs/superpowers/plans/2026-10-29-dotnet-portable-pdb/debugger-checklist.md`
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Produces: metadata `@:inlineUnlessDynamic`; private methods `Array.__hx_mapForward<S>(f:T->S):Array<S>` and `Array.__hx_filterForward(f:T->Bool):Array<T>`, holding the forwarding branches of today's `map` and `filter`.

- [ ] **Step 1: Write the failing cases**

```haxe
--- array-map-filter-inlined @gencs
// The lambdas leave no closure class, as gencs's inlined loops.
class Pt {
	public var x:Int;
	public function new(x) this.x = x;
}
class P {
	static var log = [];
	static function recv(a:Array<Int>) { log.push("recv"); return a; }
	static function fn() { log.push("fn"); return (x:Int) -> x + 1; }
	static function gen<T>(a:Array<T>, f:T->T):Array<T> return a.map(f).filter(x -> x != null);
	static function main() {
		Sys.println([1, 2, 3].map(x -> x * 2));
		Sys.println([1, 2, 3, 4].filter(x -> x % 2 == 0));
		Sys.println(["a"].map(s -> s + "!"));
		Sys.println([1.5].map(f -> Std.int(f)));
		Sys.println([new Pt(3)].map(p -> p.x));
		Sys.println([1, 2].map(x -> x > 1 ? null : x));
		var nn:Array<Null<Int>> = [1, null];
		Sys.println(nn.filter(x -> x != null));
		Sys.println(recv([1]).map(fn()));
		Sys.println(log);
		Sys.println(gen([1, 2], x -> x));
		Sys.println(gen(["z"], x -> x));
		Sys.println([[1], [2]].map(a -> a.map(x -> x + 1)));
		Sys.println(Type.resolveClass("P_main_12__Fun") == null);
		var f = [1, 2].map;
		Sys.println(f(x -> x + 10));
		var d:Dynamic = [1, 2];
		Sys.println(d.map(x -> x));
		Sys.println(Reflect.callMethod([3], Reflect.field([3], "map"), [x -> x]));
		var none:Array<Int> = null;
		try Sys.println(none.map(x -> x)) catch (e:Dynamic) Sys.println("EXC " + Type.getClassName(Type.getClass(e)));
		try Sys.println([1, 2].map(x -> { if (x == 2) throw "boom"; x; })) catch (e:String) Sys.println(e);
	}
}
===

--- array-map-filter-mutating @gencs
class P {
	static function main() {
		var a = [1, 2, 3];
		Sys.println(a.map(x -> { if (x == 1) a.push(9); x * 2; }));
		Sys.println(a);
		var b = [1];
		Sys.println(b.map(x -> { b[5] = 7; x; }));
		var c = [1, 2, 3];
		Sys.println(c.map(x -> { if (x == 1) { c.push(4); c[2] = 30; } x; }));
		var d = [1, 2, 3];
		Sys.println(d.filter(x -> { if (x == 1) d.shift(); x > 0; }));
		var e = [1, 2, 3];
		Sys.println(e.map(x -> { if (x == 1) e.unshift(0); x; }));
		var f = [1, 2, 3];
		Sys.println(f.filter(x -> { if (x == 1) f.pop(); x > 1; }));
	}
}
===

--- array-map-forwarding @gencs
// A forwarding array keeps its results through map and filter.
class P {
	static function main() {
		var o:Array<Any> = haxe.Json.parse("[1,2,3]");
		var i:Array<Int> = cast o;
		Sys.println(o.map(x -> Std.string(x) + "!"));
		Sys.println(o.filter(x -> (x : Int) > 1));
		Sys.println(i.map(x -> x + 1));
		i[1] = 20;
		Sys.println(o.map(x -> x));
	}
}
===

--- array-map-dynamic-not-inlined
// Array<Dynamic> keeps today's call: its lambda keeps its class, where gencs inlines and throws on a view.
class P {
	static function main() {
		var d:Array<Dynamic> = [1, "x"];
		Sys.println(d.map(x -> x));
		Sys.println(Type.resolveClass("P_main_5__Fun") != null);
		var ai = [1, 2];
		var view:Array<Dynamic> = ai;
		Sys.println(view.map(x -> x * 2));
		var s = [1, 2].map(x -> (x : Dynamic));
		Sys.println(Type.resolveClass("P_main_10__Fun") != null);
		Sys.println(s);
	}
}
===
[run]
[1,x]
true
[2,4]
true
[1,2]

--- array-map-dynamic-result @gencs
// The result is Array<Dynamic>, from the callback, from the expected type, or only after the call is typed.
class Pt {
	public var x = 3;
	public function new() {}
}
class P {
	static function main() {
		Sys.println([new Pt()].map(p -> Reflect.field(p, "x")));
		Sys.println([1, 2].map(x -> (x : Dynamic)));
		var e:Array<Dynamic> = [1, 2].map(x -> x);
		e.push("s");
		Sys.println(e);
		var later = [1].map(x -> null);
		var d:Array<Dynamic> = later;
		d.push("s");
		Sys.println(d);
	}
}
===

--- array-map-no-inline @gencs + -D no-inline
class P {
	static function main() {
		Sys.println([1, 2, 3].map(x -> x * 2));
		Sys.println([1, 2, 3].filter(x -> x > 1));
	}
}
===

--- array-map-dce-full @gencs + -dce full
// Under full DCE an inlined map no longer keeps the method for a by-name caller, as in gencs.
class P {
	static function main() {
		Sys.println([1].map(x -> x));
		var d:Dynamic = [1, 2];
		try Sys.println(d.map(x -> x)) catch (e:Dynamic) Sys.println("EXC");
	}
}
===

--- pdb-inlined-map-call-site @dump=pdb:P + -debug
// An inlined map's points are the call site's: no point names the runtime's Array.hx.
class P {
	static function main() {
		var a = [1, 2].map(x -> x + 1);
		Sys.println(a);
	}
}
===
```

`pdb-inlined-map-call-site`'s expectation: under `method P::main`, every point names `P.hx` or is `hidden` (format as in `pdb-two-documents`, whose `[dump]` section shows it); paste the real lines once they meet that. In `array-map-filter-inlined`, drop any line gencs cannot compile and say so in a comment.

- [ ] **Step 2: Run them, against a build of the unchanged runtime**

Run each with `--case`. Expected: `array-map-filter-inlined` fails on the `resolveClass` line (hxc has the class, gencs does not); `array-map-dynamic-not-inlined`, `array-map-dynamic-result`, `array-map-no-inline` and `array-map-forwarding` pass and pin today's behaviour; if `array-map-filter-mutating` or `array-map-dce-full` differs from gencs, it fails and stays failing only if Step 5 does not fix it.

- [ ] **Step 3: Add the rule to `Inline.tryInline`**

Once `cf`, `ethis` are known, before the `-D` checks and regardless of `forceInline`: return `null` when `TypeFunctions.hasMeta(":inlineUnlessDynamic", cf.meta)`, `ethis != null`, and `ethis.type` or `tret` follows to `TInst(_, [t])` with `t` following to `TDynamic`. A one-line comment says why (hxc's runtime `Array`: an `Array<Dynamic>` reaches every member by name). An unbound type argument still inlines; `array-map-dynamic-result`'s `later` shows that stays correct.

- [ ] **Step 4: Rewrite `map` and `filter` in `runtime/Array.hx`**

```haxe
@:inlineUnlessDynamic public inline function map<S>(f:T->S):Array<S> {
	return if (__hx_fwd != null) __hx_mapForward(f) else {
		var ret = alloc(length);
		for (i in 0...length)
			ret.__unsafe_set(i, f(__unsafe_get(i)));
		ret;
	}
}
```

`filter` likewise, with `var ret = []` and `ret.push(elt)`. Add `@:keep @:skipReflection private function __hx_mapForward<S>(f:T->S):Array<S> return __hx_resolve().map(f);` and `__hx_filterForward`, `return cast __hx_resolve().filter(f);`. `__hx_resolve()` is `Array<Dynamic>`, so the Step 3 rule leaves those calls by name: check with `ILDUMP <dll> Array __hx_mapForward` that it holds `callField ... "map"`. Correct the file's header comment (lines 33-36), which says `map` and `filter` are not inline.

- [ ] **Step 5: Rebuild; run the cases and `companion-*`, `cast-array-forward-*`, `array-*`, `method-closures`**

Expected: all pass. Then `ILDUMP <dll of array-map-filter-inlined> P main` shows no `newobj P_main_*__Fun` on the `[1, 2, 3].map` line and no `Runtime::callField`, and `Reflect.field([3], "map")` still finds the compiled `map`. If the forward branch's `f` keeps the literal from being substituted, stop and report.

- [ ] **Step 6: Update the main spec's bullet and the debugger checklist**

At main spec lines 1145-1147, the predicate passed to `Array.filter` that hxc makes a class for is now only one passed on an `Array<Dynamic>` receiver. Add to `debugger-checklist.md` a step: step over a `[1, 2].map(x -> x + 1)` line in `tests/dotnet/debugger/src/sample/Main.hx` (add the line), expect no stop in `Array.hx`, and a breakpoint on the lambda body hits.

- [ ] **Step 7: Run ALL and the own suite; commit**

Expected: all pass. The own suite covers other targets and must not move, since no other target has the metadata. Commit `Inline Array.map and filter except on Array<Dynamic>, for .NET`.

---

### Task 2: Runtime's `HxObject` overloads for Haxe-class receivers

**Files:**
- Modify: `src/hxc/codegen/dotnet/TexprDynamic.hx:318-321, 331-356, 360-377, 381-386`
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Produces: `TexprDynamic.fieldReceiver(obj:TExpr):IlSigNorm`, which pushes the receiver and returns the signature to pass as `runtimeCall`'s `first`.

- [ ] **Step 1: Write the cases**

```haxe
--- reflect-hxobject-receiver @gencs
interface I {}
class Pt implements I {
	public var x:Float = 1.5;
	public var n:Int = 2;
	public var s:String = "s";
	public function new() {}
	public function m(a:Int):Int return a + 1;
}
class Sub extends Pt {}
class G<T> {
	public var v:T;
	public function new(v) this.v = v;
}
@:nativeGen class N {
	public var y:Int = 4;
	public function new() {}
}
class P {
	static function run(name:String, f:Void->Dynamic) {
		try Sys.println(name + ": " + Std.string(f())) catch (e:Dynamic) Sys.println(name + ": EXC " + Type.getClassName(Type.getClass(e)));
	}
	static function main() {
		var p = new Pt(), sub = new Sub(), g = new G(5), n = new N();
		var i:I = p;
		var nothing:Pt = null;
		var a = {q: 9};
		run("float", () -> Reflect.field(p, "x"));
		run("int", () -> Reflect.field(p, "n"));
		run("string", () -> Reflect.field(p, "s"));
		run("sum", () -> { var t = 0.0; t += Reflect.field(p, "x"); t; });
		run("set", () -> { Reflect.setField(p, "x", 2.5); p.x; });
		run("set int", () -> { Reflect.setField(p, "n", 7); p.n; });
		run("missing", () -> Reflect.field(p, "nope"));
		run("sub", () -> Reflect.field(sub, "n"));
		run("generic", () -> Reflect.field(g, "v"));
		run("nativegen", () -> Reflect.field(n, "y"));
		run("interface", () -> Reflect.field(i, "n"));
		run("anon", () -> Reflect.field(a, "q"));
		run("null", () -> Reflect.field(nothing, "n"));
		run("null float", () -> { var t:Float = Reflect.field(nothing, "x"); t; });
		run("null set", () -> { Reflect.setField(nothing, "n", 1); 0; });
		run("call", () -> Reflect.callMethod(p, Reflect.field(p, "m"), [1]));
		var dn:Dynamic = nothing;
		run("dyn null", () -> dn.x);
	}
}
===
```

- [ ] **Step 2: Run it**

Expected: pass or fail against gencs; record which lines differ on today's build (the spec expects the `null*` lines may). Check `ILDUMP <dll> P` holds `getField_f(object` at this point.

- [ ] **Step 3: Implement `fieldReceiver`**

When `strip(obj)`'s static type follows to `TInst(c, _)` where `HxGen.isHxGen(TClassDecl(c))`, `c` is not an interface, not `:struct`, and `!g.types.isCompanionTyped(obj.type)`: push with `tl.texpr(RValue(hxObjectSig), obj)` and return `hxObjectSig` (`tl.sig(TInst(g.runtimeClass("cs.internal.HxObject"), []))`). Otherwise push as `LObject` and return `LObject`. Use it in `fieldGet`, `fieldSet`, `fieldCall` in place of `fieldHead`'s push and of the literal `LObject` passed to `runtimeCall`. `fieldHead` keeps its other callers.

- [ ] **Step 4: Remove the Float round trip in `fieldGet`**

In the `isFloat` branch: when `ret` is `RValue(LFloat64)` and `rs` is `LFloat64`, leave the `float64` and return before `finish`. Under an unsafe cast the value stays as today (`tl.keepNull`, `raw` paths untouched).

- [ ] **Step 5: Rebuild; run the case, `reflect-*`, `reflection-*`, `dynamic-*`, `companion-*`**

Expected: all pass, with every `@gencs` line matching gencs. `ILDUMP` of the case's `P` closures shows `getField_f(haxe.lang.HxObject` and no `box Double` before `toDouble` on `sum`. A line where the new overload differs from gencs is a stop-and-report.

- [ ] **Step 6: Run ALL; commit**

Expected: all pass. Commit `Use Runtime's HxObject overloads for field calls on Haxe classes, for .NET`.

---

### Task 3: Typed invokers, for static methods

**Files:**
- Modify: `src/hxc/codegen/dotnet/runtime/cs/internal/Function.hx:297-323`
- Create: `src/hxc/codegen/dotnet/MethodInvokers.hx`
- Modify: `src/hxc/codegen/dotnet/ClosuresToClass.hx:69-75, 266-288`
- Modify: `src/hxc/codegen/dotnet/GenerateDotnet.hx:63` (a new map)
- Modify: `src/hxc/codegen/dotnet/TexprCalls.hx:248-254, 669-682`
- Modify: `docs/superpowers/specs/2026-10-21-dotnet10-il-generator-design.md` (the recorded-divergences list)
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Produces, in `Function.hx`:
  - `@:keep @:abstract @:nativeGen @:native("haxe.lang.ClosureInvoker") class ClosureInvoker` with `public var __hx_arity:Int`, `new(arity:Int)`, and for N in 0–5: `__hx_accepts<N>(obj:Dynamic, <pairs>):Bool` (default `false`), `__hx_call<N>_o(obj:Dynamic, <pairs>):Dynamic` (default `null`), `__hx_call<N>_f(obj:Dynamic, <pairs>):Float` (default `0.0`), where `<pairs>` are `__fn_float<i>:Float, __fn_dyn<i>:Dynamic`.
  - `Closure` gains `public var __hx_invoker:ClosureInvoker`; its constructor is unchanged.
- Produces, in `GenerateDotnet.hx`: `DotnetCtx.methodInvokers:ObjectMap<TClassField, TClass>`, the invoker class of a method, set during `ClosuresToClass.run`.
- Produces, in `MethodInvokers.hx`: `static function eligible(g:DotnetCtx, c:TClass, cf:TClassField, isStatic:Bool):Bool` and `function note(c:TClass, cf:TClassField, isStatic:Bool):Void`.
- Produces, in `TexprCalls`: `pushInvoker(cf:TClassField):Void`, which, with the new `Closure` on the stack, leaves it there with `__hx_invoker` set if `cf` has an invoker.

- [ ] **Step 1: Write the failing cases**

```haxe
--- method-value-direct-shapes
// Which method values take the direct path: `via` looks for the by-name path's frame on the stack.
class C {
	public function new() {}
}
enum E { A; }
@:nativeGen class NG {
	public static function m(a:Int):String return P.via();
}
class O {
	@:overload public static function ov(a:Int):String return P.via();
	@:overload public static function ov(a:String):String return P.via();
}
class P {
	public static function via():String
		return Std.string(haxe.CallStack.callStack()).indexOf("__hx_invokeDynamic") < 0 ? "direct" : "by-name";
	static function sInt(a:Int):String return via();
	static function sFloat(a:Float):String return via();
	static function sBool(a:Bool):String return via();
	static function sStr(a:String):String return via();
	static function sClass(a:C):String return via();
	static function sEnum(a:E):String return via();
	static function sDyn(a:Dynamic):String return via();
	static function sFive(a:Int, b:Float, c:String, d:Bool, e:C):String return via();
	static function sVoid():Void Sys.println("void " + via());
	static inline function sInline(a:Int):String return via();
	static function sOpt(a:Int, ?b:Int):String return via();
	static function sDefault(a = 1):String return via();
	static function sRest(...r:Int):String return via();
	static function sSix(a:Int, b:Int, c:Int, d:Int, e:Int, f:Int):String return via();
	static function sGeneric<T>(a:T):String return via();
	static function sNull(a:Null<Int>):String return via();
	static function sFun(a:Int->Int):String return via();
	static function sArr(a:Array<Int>):String return via();
	static dynamic function sDynamic(a:Int):String return via();
	static function main() {
		var c = new C();
		var f1 = sInt; Sys.println("int " + f1(1));
		var f2 = sFloat; Sys.println("float " + f2(1.5));
		var f3 = sBool; Sys.println("bool " + f3(true));
		var f4 = sStr; Sys.println("string " + f4("s"));
		var f4n = sStr; Sys.println("null string " + f4n(null));
		var f5 = sClass; Sys.println("class " + f5(c));
		var f6 = sEnum; Sys.println("enum " + f6(A));
		var f7 = sDyn; Sys.println("dynamic " + f7(1));
		var f8 = sFive; Sys.println("five " + f8(1, 1.5, "s", true, c));
		var f9 = sVoid; f9();
		var f10 = sInline; Sys.println("inline " + f10(1));
		var f11 = sOpt; Sys.println("optional " + f11(1));
		var f12 = sDefault; Sys.println("default " + f12());
		var f13 = sRest; try Sys.println("rest " + f13(1)) catch (e:cs.system.ArgumentException) Sys.println("rest by-name, which throws");
		var f14 = sSix; Sys.println("six " + f14(1, 2, 3, 4, 5, 6));
		var f15:Int->String = sGeneric; Sys.println("generic " + f15(1));
		var f16 = sNull; Sys.println("null int " + f16(1));
		var f17 = sFun; Sys.println("function " + f17(x -> x));
		var f18 = sArr; Sys.println("array " + f18([1]));
		var f19 = NG.m; Sys.println("nativegen " + f19(1));
		var f20:Int->String = O.ov; Sys.println("overload " + f20(1));
		var f21 = sDynamic; Sys.println("dynamic method " + f21(1));
		var d:Dynamic = sInt; Sys.println("dynamic call, int " + d(1));
		Sys.println("dynamic call, float " + d(2.7));
	}
}
===
[run]
int direct
float direct
bool direct
string direct
null string by-name
class direct
enum direct
dynamic direct
five direct
void direct
inline direct
optional by-name
default by-name
rest by-name, which throws
six by-name
generic by-name
null int by-name
function by-name
array by-name
nativegen by-name
overload by-name
dynamic method direct
dynamic call, int direct
dynamic call, float by-name

--- method-value-static-init @gencs
class Late {
	public static var ready = init();
	static function init() { Sys.println("Late init"); return true; }
	public static function go(x:Int):Int return x + 1;
}
class P {
	static function main() {
		Sys.println("before read");
		var f = Late.go;
		Sys.println("after read");
		Sys.println(f(1));
	}
}
===

--- method-value-mistyped-args @gencs
class C { public function new() {} }
class P {
	static function inc(x:Int):Int return x + 1;
	static function half(x:Float):Float return x / 2;
	static function len(s:String):Int return s.length;
	static function isC(c:C):Bool return c != null;
	static function run(name:String, f:Void->Dynamic) {
		try Sys.println(name + ": " + Std.string(f())) catch (e:Dynamic) Sys.println(name + ": EXC " + Std.string(e));
	}
	static function main() {
		var d:Dynamic = inc;
		run("2.7", () -> d(2.7));
		run("3.5", () -> d(3.5));
		run("big", () -> d(3000000000.0));
		run("string 5", () -> d("5"));
		run("string x", () -> d("x"));
		run("bool", () -> d(true));
		run("null", () -> d(null));
		run("object", () -> d(new C()));
		run("too many", () -> d(1, 2));
		run("too few", () -> d());
		var h:Dynamic = half;
		run("float int", () -> h(3));
		run("float string", () -> h("3"));
		var l:Dynamic = len;
		run("string int", () -> l(5));
		run("string null", () -> l(null));
		var c:Dynamic = isC;
		run("class string", () -> c("s"));
		run("class null", () -> c(null));
		var f:Int->Int = inc;
		run("typed", () -> f(2));
		run("reflect", () -> Reflect.callMethod(null, inc, [2]));
	}
}
===

--- method-value-identity @gencs
class P {
	static function inc(x:Int):Int return x + 1;
	static function show(f:Dynamic) {
		Sys.println(Std.string(f) + " | " + Type.getClassName(Type.getClass(f)) + " | " + Type.typeof(f) + " | " + Reflect.isFunction(f));
	}
	static function main() {
		show(inc);
		var a = inc, b = inc;
		Sys.println(a == b);
		Sys.println(Reflect.compareMethods(a, b));
		Sys.println(Reflect.compareMethods(a, Reflect.field(P, "inc")));
		Sys.println(Reflect.compareMethods(Reflect.field(P, "inc"), a));
		try haxe.Serializer.run(a) catch (e:Dynamic) Sys.println("EXC " + e);
	}
}
===

--- method-value-throws
// A throwing method value: same exception and message, and the program's own frames in order. `boom` has a
// loop, so the JIT does not inline it.
class P {
	static function boom(x:Int):Int {
		for (i in 0...x) if (i == 2) throw "bang";
		return x;
	}
	static function nat(s:String):Int {
		var n = 0;
		for (i in 0...2) n += s.length;
		return n;
	}
	static function natDirect(x:Int):Int {
		var s:String = null;
		var n = 0;
		for (i in 0...x) n += s.length;
		return n;
	}
	static function call(f:Int->Int, x:Int):Int return f(x);
	static function frames(st:haxe.CallStack):Array<String> {
		var out = [];
		function walk(i:haxe.CallStack.StackItem) switch i {
			case FilePos(s, _, _, _) if (s != null): walk(s);
			case Method(c, m) if (c == "P"): out.push(c + "." + m);
			case _:
		}
		for (i in st) walk(i);
		return out;
	}
	static function main() {
		try call(boom, 5) catch (e:haxe.Exception) {
			Sys.println(e.message);
			Sys.println(frames(e.stack));
		}
		var g = nat;
		try g(null) catch (e:cs.system.NullReferenceException) Sys.println(e.GetType().FullName + ": " + e.Message);
		var h = natDirect;
		try h(1) catch (e:cs.system.NullReferenceException) Sys.println(e.GetType().FullName + ": " + e.Message);
	}
}
===
[run]
bang
[P.boom,P.call,P.main,P.Main]
System.NullReferenceException: Object reference not set to an instance of an object.
System.NullReferenceException: Object reference not set to an instance of an object.

--- method-value-pdb @dump=pdb:P_inc__Invoke + -debug
// The invoker class is generated code: all its points are hidden.
class P {
	static function inc(x:Int):Int return x + 1;
	static function main() {
		var f = inc;
		Sys.println(f(1));
	}
}
===
```

`g(null)` goes by name by the table, `h(1)` directly. `method-value-pdb`'s expectation: every point of every method of the invoker class is `hidden`; paste the real lines once they meet that.

- [ ] **Step 2: Run them on today's build**

Expected: `method-value-direct-shapes` fails (the direct lines print `by-name`, except `dynamic method`); `method-value-pdb` fails (no such class); the other four pass and pin today's behaviour. The `throws` expectation and the by-name lines were checked against the compiler at the branch point, so a failure there is a bug in how the case was entered.

- [ ] **Step 3: Add `ClosureInvoker` and `Closure`'s overrides to `Function.hx`**

In the file's explicit style, for N in 0–5, each of `_o` and `_f`:

```haxe
override public function __hx_invoke1_o(__fn_float1:Float, __fn_dyn1:Dynamic):Dynamic {
	var inv = __hx_invoker;
	if (inv != null && inv.__hx_arity == 1 && inv.__hx_accepts1(obj, __fn_float1, __fn_dyn1))
		return inv.__hx_call1_o(obj, __fn_float1, __fn_dyn1);
	return super.__hx_invoke1_o(__fn_float1, __fn_dyn1);
}
```

`__hx_invokeDynamic`, `Equals`, `GetHashCode` stay as they are.

- [ ] **Step 4: Implement `MethodInvokers.eligible`**

True only when all hold (ruling C):
- `c` is not extern, not an interface, not `:struct`, and `HxGen.isHxGen(TClassDecl(c))`.
- `c.params` is empty, and every superclass has no type parameters.
- `cf` has no `params`, no overloads and no `CfOverload`, kind `Method(MethNormal | MethInline)`, no `:skipReflection`, no `:native`.
- Its signature has at most 5 arguments, none `opt`, none `haxe.Rest`.
- Each argument follows to: `Int`, `Float`, `Bool`, `String`, `Dynamic`, a `TInst` with no type arguments that is not a type parameter, or a `TEnum` with no type arguments.
- The return follows to one of those, or `Void`.
- For a static: no superclass declares a static with the same name (the by-name path rates candidates across the hierarchy).

- [ ] **Step 5: Implement `MethodInvokers.note` to build the class**

Once per `cf` (keyed by `g.methodInvokers`), as `ClosuresToClass.closure` builds a closure class, a `:nativeGen` class in `c`'s module and package:
- Named `<Class>_<method>__Invoke`, adding `_0`, `_1`, … while `taken` holds the path.
- `superClass` is `ClosureInvoker`; the constructor calls `super(arity)`.
- A static `__hx_current` as in `closure`.
- `g.addClosureClass(invoker, c)` and `added.push(invoker)`.

Overrides, as typed AST, all at `Position.nullPos` under `-debug` and `cf.pos` otherwise:
- `__hx_accepts<N>`: per argument, with `d` the Dynamic half and `f` the Float half, `undef` being `d == Runtime.undefined`. `Int`: `undef ? (f == (double)(int)f) : __is__(d, Int)`. `Float`: `undef || __is__(d, Float)`. `Dynamic`: `true`. Others: `__is__(d, T)`, so a null goes by name. Instance receiver test is in Task 4; a static ignores `obj`.
- `__hx_call<N>_o`: unpack each argument with `ClosuresToClass`'s `fromFloat` and a cast, as `invokeMethod` does; `TCall` of `TField(TTypeExpr(c), FStatic(c, cf))`; return the value as `Dynamic`, or `null` for `Void`.
- `__hx_call<N>_f`: the same call. `Int`/`Float` return converts to Float directly; `Void` returns `0.0`; any other return goes through `Runtime.toDouble` of the `Dynamic`, as `VarArgsBase` does.

`_o` must box an `Int` result as an `Int`, not a Double, to match the by-name path.

- [ ] **Step 6: Wire it in**

- `ClosuresToClass.run`: `g.runtimeClass("cs.internal.ClosureInvoker")` must exist, or no invokers.
- `ClosuresToClass.map`: before the default branch, a `TCall` whose callee is a `TField` maps its receiver and arguments and keeps the field (a call is not a value); a `TField(_, FStatic(c, cf))` where `isMethod`-kind and `eligible` calls `note`. The `delegate` path is untouched, as its case comes first.
- `TexprCalls.pushInvoker(cf)`: when `g.methodInvokers.get(cf)` is set, emit `dup`, the lazy `__hx_current` (`ldsfld`, `dup`, `brtrue` to a label, `pop`, `newobj`, `dup`, `stsfld`), `stfld Closure.__hx_invoker`. The field and constructor tokens come from `tl.staticField` and `g.planOf`, as `pushClosure` finds its constructor. Call it after `pushClosure` in the `FStatic` case only (`TexprCalls.hx:253`).

- [ ] **Step 7: Rebuild; run the cases and `method-closures`, `function-value-shapes`, `closure-identity`, `reflect-api`**

Expected: all pass. `ILVerify` clean. In `method-value-direct-shapes` the instance lines are not there yet. Any `direct` where the table says `by-name` (or the reverse) is a bug in `eligible` or `__hx_accepts`, not in the case.

- [ ] **Step 8: Record the divergence in the main spec**

In the recorded-divergences list: `haxe.lang.Closure` has more public members than gencs's (`__hx_invoker`, the `__hx_invoke<N>` overrides), seen only by .NET reflection over the runtime type such as `Type.getInstanceFields(Type.getClass(f))`; and there is one generated `*__Invoke` class per method used as a value, as with the closure classes in that list. Also the frame list of a throwing method value (spec, decision).

- [ ] **Step 9: Run ALL; commit**

Expected: all pass, plus `method-value-*`. Commit `Call static methods used as values directly, through a typed invoker, for .NET`.

---

### Task 4: Typed invokers, for instance methods

**Files:**
- Modify: `src/hxc/codegen/dotnet/MethodInvokers.hx`
- Modify: `src/hxc/codegen/dotnet/ClosuresToClass.hx` (`map`)
- Modify: `src/hxc/codegen/dotnet/TexprCalls.hx:308-313`
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: Task 3's `eligible`, `note`, `pushInvoker`, `ClosureInvoker`.

- [ ] **Step 1: Write the failing cases**

```haxe
--- method-value-instance-direct
class Base {
	public var tag = "b";
	public function new() {}
	public function hello(n:Int):String return tag + n + " " + P.via();
	public function over(n:Int):String return "base " + P.via();
	public function callSuper():Int->String return superVia;
	function superVia(n:Int):String return P.via();
}
class Sub extends Base {
	override public function over(n:Int):String return "sub " + P.via();
}
class G<T> {
	public function new() {}
	public function g(x:Int):String return P.via();
}
interface I { function im(x:Int):String; }
class Impl implements I {
	public function new() {}
	public function im(x:Int):String return P.via();
}
class P {
	public static function via():String
		return Std.string(haxe.CallStack.callStack()).indexOf("__hx_invokeDynamic") < 0 ? "direct" : "by-name";
	static function main() {
		var b = new Base();
		var f = b.hello; Sys.println(f(1));
		b.tag = "B"; Sys.println(f(2));
		var bs:Base = new Sub();
		var o = bs.over; Sys.println(o(1));
		var s = b.callSuper(); Sys.println(s(1));
		var g = new G<Int>().g; Sys.println("generic class " + g(1));
		var i:I = new Impl();
		var m = i.im; Sys.println("interface " + m(1));
		var im = new Impl().im; Sys.println("class implementing " + im(1));
	}
}
===
[run]
b1 direct
B2 direct
sub direct
direct
generic class by-name
interface by-name
class implementing direct

--- method-value-null-receiver @gencs
class C {
	public var n = 1;
	public function new() {}
	public function m(x:Int):Int return x + n;
}
class P {
	static function run(name:String, f:Void->Dynamic) {
		try Sys.println(name + ": " + Std.string(f())) catch (e:Dynamic) Sys.println(name + ": EXC " + Type.getClassName(Type.getClass(e)));
	}
	static function main() {
		var nothing:C = null;
		run("read", () -> { var f = nothing.m; "read ok"; });
		run("call", () -> { var f = nothing.m; f(1); });
		var wrong:C = cast new P();
		run("wrong type", () -> { var f = wrong.m; f(1); });
	}
	function new() {}
}
===

--- method-value-instance-equality @gencs
class C {
	public function new() {}
	public function m(x:Int):Int return x;
}
class P {
	static function main() {
		var a = new C(), b = new C();
		Sys.println(Reflect.compareMethods(a.m, a.m));
		Sys.println(Reflect.compareMethods(a.m, b.m));
		Sys.println(Reflect.compareMethods(a.m, Reflect.field(a, "m")));
		var f = a.m, g = a.m;
		Sys.println(f == g);
		var d:Dynamic = a.m;
		Sys.println(d(1));
		Sys.println(d("2"));
	}
}
===
```

- [ ] **Step 2: Run them**

Expected: `method-value-instance-direct` fails (`by-name` everywhere); the other two pass.

- [ ] **Step 3: Extend `MethodInvokers` to instance methods**

In `__hx_accepts<N>`, first test `__is__(obj, c)`, so a null or wrongly typed receiver goes by name. In `__hx_call<N>_*`, cast `obj` to `c` and `TCall` `TField(cast, FInstance(c, [], cf))`, which lowers to `callvirt`. No `super` receivers: Haxe refuses `super.f` as a value.

- [ ] **Step 4: Wire it in**

`ClosuresToClass.map`: note `TField(_, FInstance(c, _, cf) | FClosure({c: c}, cf))` when `cf` is a method and `eligible`. `TexprCalls.fieldRead`, the instance-method case at line 312: `pushInvoker(cf)` after `pushClosure`, leaving the other `pushClosure` cases (String, extern, enum, dynamic array) alone.

- [ ] **Step 5: Rebuild; run the cases and `method-closures`, `function-value-shapes`, `closure-identity`, `companion-*`**

Expected: all pass.

- [ ] **Step 6: Run ALL and the own suite; commit**

Expected: all pass. Commit `Call instance methods used as values directly, through a typed invoker, for .NET`.

---

### Task 5: Measure and report

**Files:**
- Modify: `docs/superpowers/plans/2026-10-29-dotnet-portable-pdb/debugger-checklist.md`
- Modify: `README.md` (only if it describes method values or `Array.map` as slow; else nothing)

- [ ] **Step 1: Rebuild the benchmark with the new compiler**

Run: `bash D:/_github/hxc/.superpowers/research/hxc5-perf/build.sh <worktree>/bin/cpp/windows/x64/release/bin/hxc.exe`
Expected: both DLLs listed. `build.sh` wipes `out/`; the old numbers and DLL are in `baseline-7e5a1219/`.

- [ ] **Step 2: Time it, with nothing else running**

Run: `bash D:/_github/hxc/.superpowers/research/hxc5-perf/interleave.sh 3`, then `interleave.sh 2 method-ref`; compare with `baseline-7e5a1219/interleaved.txt`. Baseline `method-ref`: gencs about 8,500 ms, hxc about 8,800 ms.
Expected, per the spec: `array-map-filter` and `reflect-field` at or below 1.1× gencs; `method-ref` at least 50× faster than the hxc baseline; no other benchmark over 10% slower than its baseline, rechecking any that is with `interleave.sh 5 <name>`, since other sessions skew single runs by up to 2×.

If a target is missed, stop and report the numbers and `ILDUMP` of the path; do not tune outside this plan's tasks.

- [ ] **Step 3: Add the method-value step to the debugger checklist**

In `debugger-checklist.md`: passing a method as a value (add it to `tests/dotnet/debugger/src/sample/Main.hx`), set a breakpoint in the method, expect it to hit, and step out to land in the caller with no stop in `*__Invoke` or `Function.hx`. The person driving this runs the checklist by hand.

- [ ] **Step 4: Check the deterministic and debug paths once more; commit**

Run ALL. Expected: all pass. Commit `Add debugger steps for inlined map and method values, for .NET`. Report the Step 2 table in the final message.
