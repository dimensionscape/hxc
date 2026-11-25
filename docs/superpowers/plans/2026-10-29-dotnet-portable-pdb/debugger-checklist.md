# Debugger checklist, .NET Portable PDB

Run by hand, in VS Code and then in Visual Studio 2022 or later. Each item says what to open, where to
click and what should appear; write what happened on its `Result:` line (what appeared, or what went
wrong, with the exact text of any message).

## Setup

1. Build the sample: in `tests/dotnet/debugger` (relative to the repo root), run `hxc build.hxml` (with
   `HAXE_STD_PATH=C:/HaxeToolkit/haxe/std` set). `out/out.dll` and `out/out.pdb` appear.
2. `dotnet out/out.dll` prints eight lines, each naming `src/sample/Main.hx` and a line number:
   `total 28`, `inner 56`, `closure 15`, `caught side too large: 3`, `field 42`, `mapped [2,3]`,
   `static value 2`, `instance value 5`.
3. `-D dotnet-debug-jit` makes the PDB name files by full path, so a debugger needs no source map; only
   `hxc-runtime/...` keeps a short name, with its text embedded.

The lines used below (1-based):

| File | Line | Code |
| --- | --- | --- |
| `src/sample/Main.hx` | 7 | `var count = 3;` (the loop is not unrolled, because its bound is a variable) |
| `src/sample/Main.hx` | 8 | `for (i in 0...count) {` |
| `src/sample/Main.hx` | 9 | `var side = i + 1;` |
| `src/sample/Main.hx` | 10 | `total += shapes.area(side);` |
| `src/sample/Main.hx` | 12 | `trace("total " + total);` (after the loop) |
| `src/sample/Main.hx` | 14 | `var inner = total * 2;` (inside the inner block) |
| `src/sample/Main.hx` | 15 | `trace("inner " + inner);` |
| `src/sample/Main.hx` | 19 | `trace("closure " + add(5));` |
| `src/sample/Main.hx` | 21 | `shapes.fail(3);` (inside the `try`) |
| `src/sample/Main.hx` | 25 | `trace("field " + Reflect.field(...));` |
| `src/sample/Main.hx` | 26 | `var mapped = [1, 2].map(x -> x + 1);` |
| `src/sample/Main.hx` | 27 | `trace("mapped " + mapped);` |
| `src/sample/Main.hx` | 28 | `var viaStatic = apply(bump, 1);` |
| `src/sample/Main.hx` | 30 | `var viaInstance = apply(shapes.grow, 3);` |
| `src/sample/Main.hx` | 35 | `return f(x);` (in `apply`) |
| `src/sample/Main.hx` | 39 | `var y = x + 1;` (in `bump`) |
| `src/sample/Shapes.hx` | 11 | `var squared = side * side;` |
| `src/sample/Shapes.hx` | 12 | `var result = squared * scale;` |
| `src/sample/Shapes.hx` | 18 | `throw "side too large: " + side;` |
| `src/sample/Shapes.hx` | 23 | `var grown = side + scale;` (in `grow`) |

## VS Code

Prerequisite: the C# extension (or C# Dev Kit), which provides the `coreclr` debugger.

Open the folder `tests/dotnet/debugger` of the checkout (File > Open Folder). Its
`.vscode/launch.json` launches `out/out.dll` with `"justMyCode": false` and looks for the PDB in `out/`.

1. **Breakpoint binding, before the program starts.** Open
   `src/sample/Shapes.hx`, click in the gutter left of line 11 to set a breakpoint, then press F5
   (start "Debug the sample (.NET)"). The breakpoint binds if its dot stays solid red once the debugger
   has started (it does not turn hollow grey with a "will not currently be hit" message) and execution
   stops on line 11 with the line highlighted. A dot that is solid only before F5 proves nothing.
   Result: stopped on line 11 (VS Code's C# debugger, driven through its toolbar commands, DAP messages
   logged). With short names and no `sourceFileMap` it binds and stops too, then cannot open the file:
   `Could not load source 'src/data/Puzzles.hx': Incorrect format of 'source' message.` Hence full paths.
2. **Step over.** (The items go over, out, into because item 1 already stops inside `Shapes.hx`.) Press F10. The highlight moves to line 12.
   Result: moved to line 12, then line 13. Continue stopped at line 11 again, on the next iteration.
3. **Step out.** Press Shift+F11. Execution returns to `src/sample/Main.hx`, at line 10 (the call site) or
   the line after it, and the Call Stack shows `sample.Main.main` at a `.hx` line.
   Result:
4. **Step into the other file.** Remove the breakpoint in `Shapes.hx`, set one on `src/sample/Main.hx`
   line 10 and restart (Ctrl+Shift+F5). When it stops on line 10, press F11. Execution enters
   `src/sample/Shapes.hx` at line 11, and that file is the one shown.
   Result:
5. **Stepping stops at the loop's line on every iteration.** With the breakpoint on `src/sample/Main.hx`
   line 10, continue to it, then press F10 repeatedly through the end of the loop body. Does stepping stop
   on line 8 (`for`) each time the loop comes round, then on line 9 and line 10 again? Check all three
   iterations (the Variables pane shows `i` as 0, 1, 2). Write down any iteration where line 8 is skipped.
   After the third iteration, stepping goes on to line 12.
   Result:
6. **Locals in the inner block.** Set a breakpoint on `src/sample/Main.hx` line 15 and continue (F5) to it.
   The Variables pane, under Locals, lists at least `inner` (56), `shapes`, `total` and `count` by their Haxe
   names; `offset` and `add` (declared later in the method, not yet assigned) are listed too, and `i` and
   `side` are not. Step (F10) until line 19, which is after the block (lines 17 and 18 stop on the way):
   `inner` is no longer listed.
   Result:
7. **A Watch of a local in C# syntax.** While stopped on line 15, add `total + 1` to the Watch pane. It
   shows 29, with no error.
   Result:
8. **A Watch in Haxe-only syntax.** Add each of `[total, 1]` (an array literal, Haxe-only),
   `cast(total, Int)` and `if (total > 0) 1 else 2` to the Watch pane. Note which show a value and which
   show an error, with the error text.
   Result:
9. **Stepping into `Reflect.field` shows hxc's runtime source.** Set a breakpoint on `src/sample/Main.hx`
   line 25 and continue to it. Press F11 until execution is inside `Reflect.field`. A source file opens:
   either `cs/_std/Reflect.hx` under the Haxe std folder or a tab named `hxc-runtime/...` holding
   hxc's embedded text. Write down the name, which of the two it is, and whether stepping goes on line by
   line in it. If a "source not available" page opens instead, copy its text.
   Result:
10. **An exception's Call Stack.** Remove other breakpoints, set one on `src/sample/Shapes.hx` line 18 (the
    `throw`), restart and continue until it stops there. The Call Stack is expected to list
    `sample.Shapes.fail` at `src/sample/Shapes.hx:18` and `sample.Main.main` at `src/sample/Main.hx:21`:
    `.hx` files and lines. Then press F5 and let the exception run to its catch. (Ticking "All Exceptions"
    instead stops first on first-chance exceptions inside the runtime, because `justMyCode` is false;
    press Continue past those, and write down what they were.)
    Result:
11. **Stepping over an inlined `map`.** (What this item expects is a prediction read from the PDB under
    `justMyCode: false`; it has not been run in a debugger, so write down what happens.) Remove other
    breakpoints, set one on `src/sample/Main.hx` line 26 and restart. When it stops there, press F10.
    Execution moves to line 27, and no tab for hxc's runtime `Array.hx` opens. Restart, stop on line 26 again
    and press F11 a few times. F11 may stop in `hxc-runtime/Array.hx` (`Array.__unsafe_get`, lines 740-742,
    and the other real calls the loop makes), with an `Array` frame above `sample.Main.main` in the Call
    Stack. Shift+F11 goes back to `src/sample/Main.hx`, line 26, which the loop and the lambda body `x + 1`
    are all on. Write down where each F11 stopped.
    Result:
12. **Stepping through a method used as a value.** (What this item expects is a prediction read from the
    PDB under `justMyCode: false`; it has not been run in a debugger, so write down what happens.) Remove
    other breakpoints, set one on `src/sample/Main.hx` line 39 (the static method `bump`) and one on
    `src/sample/Shapes.hx` line 23 (the instance method `grow`), and restart. `main` passes each to `apply`
    as a value (lines 28 and 30), and `apply` calls it as `f(x)` on line 35. Both breakpoints are expected to
    hit: first line 39, then line 23. At each stop the Call Stack lists the method (`sample.Main.bump`, then
    `sample.Shapes.grow`), `sample.Main.apply` at `src/sample/Main.hx:35` and `sample.Main.main` at `.hx`
    lines. Between the method and `apply` it may show `haxe.lang.Closure.__hx_invoke1_f` in
    `hxc-runtime/cs/internal/Function.hx` and a frame named `*__Invoke` (`sample.Main_bump__Invoke.__hx_call1_f`).
    **The check:** a `*__Invoke` frame has no source line, and is not shown as the program's own code. Write
    down the frames as listed. Press Shift+F11 at each stop: execution may stop in `Function.hx` on the way
    back to `sample.Main.apply`; it does not open a source line for a `*__Invoke` method. Then restart with
    only a breakpoint on `src/sample/Main.hx` line 28 and press F10: execution moves to line 29, with no stop
    in another file. Restart with only a breakpoint on line 35 and press F10: stepping stays in
    `src/sample/Main.hx`. Restart again, stop on line 35 and press F11 until execution is in `bump`, at line
    39 (the first time `apply` runs): F11 may stop in `Function.hx` on the way, and does not stop at a source
    line of a `*__Invoke` method. Write down each stop.
    Result:

## Visual Studio 2022 or later

Prerequisite: a Visual Studio with the ".NET desktop development" workload.

Visual Studio cannot open a DLL as a project, so start it through a console project: create any C#
Console project, open its Properties > Debug > Launch Profiles, and add an "Executable" profile whose
executable is `dotnet` and whose arguments are the full path of `tests/dotnet/debugger/out/out.dll` in
your checkout; select that profile. (The project's own program does not run.) Then set up symbols, with
`<sample>` meaning the full path of `tests/dotnet/debugger` in your checkout:

- Tools > Options > Debugging > Symbols: add the folder `<sample>/out`.
- Tools > Options > Debugging > General: untick "Enable Just My Code".

Write in item 1's Result how you started the program, and which of these settings you had to use.

1. **Breakpoint binding, before the program starts.** With the settings
   above, open `src/sample/Shapes.hx` (File > Open > File) and click the margin left of line 11. Press F5.
   The breakpoint binds if its circle stays solid red once debugging has started (it does not turn hollow
   with "The breakpoint will not currently be hit") and execution stops on line 11. A circle that is
   solid only before F5 proves nothing. If it does not bind, you need a stopped frame to try "Find source"
   on; the sample exits in milliseconds, so get one this way, not with Break All: start with Debug > Step
   Into (F11), which stops at the program's first line, or tick "Common Language Runtime Exceptions" in
   Debug > Windows > Exception Settings, so that the sample breaks when it throws. In the Call Stack
   double-click a `sample.Main.main` or `sample.Shapes.fail` frame, choose "Find source" and select
   `src/sample/Main.hx` or `Shapes.hx`; say whether a breakpoint on line 11 then binds on a restart.
   Result:
2. **Step over.** (The items go over, out, into because item 1 already stops inside `Shapes.hx`.) Press F10. The yellow arrow moves to line 12.
   Result:
3. **Step out.** Press Shift+F11. Execution returns to `src/sample/Main.hx`, at line 10 or the line after it.
   Result:
4. **Step into the other file.** Remove the breakpoint in `Shapes.hx`, set one on `src/sample/Main.hx`
   line 10 and restart. When it stops on line 10, press F11. The yellow arrow goes to
   `src/sample/Shapes.hx` line 11, and that file is shown.
   Result:
5. **Stepping stops at the loop's line on every iteration.** With the breakpoint on `src/sample/Main.hx`
   line 10, continue to it, then press F10 repeatedly through the end of the loop body. Does stepping stop
   on line 8 (`for`) each time the loop comes round, then on line 9 and line 10 again? Check all three
   iterations. Write down any iteration where line 8 is skipped. After the third iteration, stepping goes
   on to line 12.
   Result:
6. **Locals in the inner block.** Break on `src/sample/Main.hx` line 15; open Debug > Windows > Locals.
   At least `inner` (56), `shapes`, `total` and `count` are listed by their Haxe names; `offset` and `add`
   (declared later in the method, not yet assigned) are listed too, and `i` and `side` are not. Step (F10)
   until line 19 (lines 17 and 18 stop on the way): `inner` is gone.
   Result:
7. **A Watch of a local in C# syntax.** In Debug > Windows > Watch > Watch 1 add `total + 1`. It shows 29,
   with no error.
   Result:
8. **A Watch in Haxe-only syntax.** Add each of `[total, 1]`, `cast(total, Int)` and
   `if (total > 0) 1 else 2` to Watch 1. Note which show a value and which show an error, with the error
   text. (The Document language is C#'s, so C# syntax is expected to work and Haxe-only syntax not to.)
   Result:
9. **Stepping into `Reflect.field` shows hxc's runtime source.** Break on `src/sample/Main.hx` line 25 and
   press F11 until execution is inside `Reflect.field`. A document opens: `haxe-std/cs/_std/Reflect.hx`, or
   `hxc-runtime/...` holding hxc's embedded text. Write down the name, which of the two it is, and whether
   stepping goes on line by line in it.
   Result:
10. **An exception's Call Stack.** Remove other breakpoints; in Debug > Windows > Exception Settings tick
    "Common Language Runtime Exceptions" (or break on `src/sample/Shapes.hx` line 18). Start debugging.
    When execution stops at the throw, the Call Stack window is expected to list `sample.Shapes.fail` at
    `src/sample/Shapes.hx` line 18 and `sample.Main.main` at `src/sample/Main.hx` line 21. (With Just My
    Code off, an exception setting may stop first inside the runtime; the breakpoint on line 18 avoids
    that. Write down what the stops were.)
    Result:
11. **Stepping over an inlined `map`.** (What this item expects is a prediction read from the PDB with Just
    My Code off; it has not been run in a debugger, so write down what happens.) Remove other breakpoints,
    set one on `src/sample/Main.hx` line 26 and restart. When it stops there, press F10. The yellow arrow
    moves to line 27, and no document for hxc's runtime `Array.hx` opens. Restart, stop on line 26 again and
    press F11 a few times. F11 may stop in `hxc-runtime/Array.hx` (`Array.__unsafe_get`, lines 740-742, and
    the other real calls the loop makes), with an `Array` frame above `sample.Main.main` in the Call Stack.
    Shift+F11 goes back to `src/sample/Main.hx`, line 26, which the loop and the lambda body `x + 1` are all
    on. Write down where each F11 stopped.
    Result:
12. **Stepping through a method used as a value.** (What this item expects is a prediction read from the
    PDB with Just My Code off; it has not been run in a debugger, so write down what happens.) Remove other
    breakpoints, set one on `src/sample/Main.hx` line 39 (the static method `bump`) and one on
    `src/sample/Shapes.hx` line 23 (the instance method `grow`), and restart. `main` passes each to `apply`
    as a value (lines 28 and 30), and `apply` calls it as `f(x)` on line 35. Both breakpoints are expected to
    hit: first line 39, then line 23. At each stop the Call Stack lists the method (`sample.Main.bump`, then
    `sample.Shapes.grow`), `sample.Main.apply` at `src/sample/Main.hx:35` and `sample.Main.main` at `.hx`
    lines. Between the method and `apply` it may show `haxe.lang.Closure.__hx_invoke1_f` in
    `hxc-runtime/cs/internal/Function.hx` and a frame named `*__Invoke` (`sample.Main_bump__Invoke.__hx_call1_f`).
    **The check:** a `*__Invoke` frame has no source line, and is not shown as the program's own code. Write
    down the frames as listed. Press Shift+F11 at each stop: the yellow arrow may stop in `Function.hx` on the
    way back to `sample.Main.apply`; it does not open a source line for a `*__Invoke` method. Then restart
    with only a breakpoint on `src/sample/Main.hx` line 28 and press F10: the yellow arrow moves to line 29,
    with no stop in another file. Restart with only a breakpoint on line 35 and press F10: stepping stays in
    `src/sample/Main.hx`. Restart again, stop on line 35 and press F11 until the yellow arrow is in `bump`, at
    line 39 (the first time `apply` runs): F11 may stop in `Function.hx` on the way, and does not stop at a
    source line of a `*__Invoke` method. Write down each stop.
    Result:
