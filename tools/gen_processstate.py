"""Generate src/hxc/core/ProcessState.hx: every static under src/hxc whose fresh-process value comes from no
boot code (no initializer, or `= null`), reset to that value when a wasm host runs main again in the same instance.
Rerun it after adding such a static.

usage: python tools/gen_processstate.py [--check]   (--check: exit 1 if the file is out of step)
"""
import os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..", "src").replace("\\", "/") + "/"


def blank(src):
    """src with comments, and the insides of string and regex literals, turned to spaces (newlines kept): a
    brace or a `#else` in the C of a @:cppFileCode string is not Haxe's."""
    out = []
    i = 0
    n = len(src)
    while i < n:
        c = src[i]
        two = src[i:i + 2]
        keep = 0
        if two == "//":
            j = src.find("\n", i)
            if j < 0: j = n
        elif two == "/*":
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
        elif two == "~/" or c in "\"'":
            end = "/" if c == "~" else c
            keep = 2 if c == "~" else 1
            j = i + keep
            while j < n and src[j] != end: j += 2 if src[j] == "\\" else 1
            j = min(j + 1, n)
        else:
            out.append(c)
            i += 1
            continue
        out.append(src[i:i + keep] + re.sub(r"[^\n]", " ", src[i + keep:j - 1 if keep else j]) + (src[j - 1] if keep else ""))
        i = j
    return "".join(out)


def condition_at(s, i):
    """The condition of a `#if` or `#elseif` whose keyword ends at s[i]: one term, as Haxe reads it."""
    while i < len(s) and s[i] in " \t": i += 1
    j = i
    while j < len(s) and s[j] == "!": j += 1
    if j < len(s) and s[j] == "(":
        d = 0
        while j < len(s):
            d += (s[j] == "(") - (s[j] == ")")
            j += 1
            if d == 0: break
    else:
        m = re.compile(r"[\w.]+").match(s, j)
        if m: j = m.end()
    return s[i:j]


def negated(term):
    return term[1:] if term.startswith("!") and not term.startswith("!!") else "!" + term


def condition_of(stack):
    """The `#if` blocks open at a line, as one condition ("" outside all of them)."""
    terms = []
    for earlier, current in stack:
        terms += [negated(t) for t in earlier]
        if current is not None: terms.append(current)
    return terms[0] if len(terms) == 1 else "(" + " && ".join(terms) + ")" if terms else ""


def guarded(items, indent):
    """Lines for (condition, text) pairs, neighbours under one condition sharing a `#if`."""
    out = []
    open_cond = ""
    for cond, text in items:
        if cond != open_cond:
            if open_cond: out.append(indent + "#end")
            if cond: out.append(indent + "#if " + cond)
            open_cond = cond
        out.append(indent + text)
    if open_cond: out.append(indent + "#end")
    return "\n".join(out)


rows = []
class_conds = {}
for dp, ds, fs in os.walk(ROOT + "hxc"):
    # the .NET runtime is source text RuntimeSources embeds for the program being compiled, not the compiler's own code
    if dp.replace("\\", "/").endswith("hxc/codegen/dotnet"): ds[:] = [d for d in ds if d != "runtime"]
    ds.sort()
    for f in sorted(fs):
        if not f.endswith(".hx") or f == "ProcessState.hx": continue
        p = os.path.join(dp, f).replace("\\", "/")
        src = open(p, encoding="utf-8-sig").read()
        code = blank(src)
        pm = re.search(r"^\s*package\s+([\w.]+)\s*;", code, re.M)
        if not pm:
            print("no package:", p); continue
        pkg = pm.group(1)
        # class-level statics only: track the enclosing class by `class Name` declarations at depth 0/1
        # and the `#if` blocks open at each line: a static only some hosts declare is reset under the same condition
        depth = 0
        cls = None
        conds = []
        lines = code.split("\n")
        for ln in lines:
            for dm in re.finditer(r"#(if|elseif|else|end)\b", ln):
                word = dm.group(1)
                if word == "if": conds.append(([], condition_at(ln, dm.end())))
                elif not conds: sys.exit("%s: #%s outside a #if" % (p, word))
                elif word == "end": conds.pop()
                else:
                    earlier, current = conds[-1]
                    conds[-1] = (earlier + [current], condition_at(ln, dm.end()) if word == "elseif" else None)
            m = re.match(r"^(?:@:[\w.]+(?:\([^)]*\))?\s*)*(?:(?:private|extern|final|abstract)\s+)*(class|abstract|interface|enum)\s+(\w+)", ln.strip()) if depth == 0 else None
            if m and m.group(1) == "class":
                cls = m.group(2)
                class_conds["%s.%s" % (pkg, cls)] = condition_of(conds)
            elif m: cls = None
            if depth == 1 and cls:
                sm = re.match(r"^\s*((?:public |private |@:\w+(?:\([^)]*\))? )*)static (var|final) (\w+)\s*(?::\s*([^=;]+?))?\s*(=\s*null\s*)?;\s*$", ln)
                if sm and "inline" not in sm.group(1):
                    ty = (sm.group(4) or "").strip()
                    rows.append((pkg, os.path.basename(p)[:-3], cls, sm.group(3), ty, sm.group(2), condition_of(conds)))
            depth += ln.count("{") - ln.count("}")
        if conds: sys.exit("%s: a #if is still open at the end" % p)


def zero(ty):
    if ty in ("Int", "UInt"): return "0"
    if ty == "Float": return "0.0"
    if ty == "Bool": return "false"
    return "null"


accesses = sorted({"%s.%s" % (pkg, cls) for pkg, mod, cls, _, _, _, _ in rows})
body = []
for pkg, mod, cls, name, ty, kind, cond in rows:
    path = "%s.%s" % (pkg, cls) if mod == cls else "%s.%s.%s" % (pkg, mod, cls)
    if kind == "final": continue
    body.append((cond, "%s.%s = %s;" % (path, name, zero(ty))))
out = """package hxc.core;

/**
	The statics whose value in a fresh process comes from no initializer (none, or `= null`). A host that runs
	the compiler's main again in the same process (a wasm instance re-entered with callMain) re-runs every
	static initializer but keeps these, and a compilation left in them stays reachable: Compiler.main resets
	them on re-entry. Generated by tools/gen_processstate.py; rerun it when such a static is added.
**/
%s
#if emscripten
@:cppFileCode("#include <emscripten/stack.h>\n#include <stdlib.h>\n#include <string.h>\nstatic void hxc_clear_stack(char *top) { char *lo = (char *)emscripten_stack_get_end(); if (top > lo) memset(lo, 0, top - lo); }\nstatic void hxc_clear_stack_and_exit(int code) { hxc_clear_stack((char *)emscripten_stack_get_base()); exit(code); }")
#end
class ProcessState {
	public static function resetUninitializedStatics():Void {
%s
	}

	/**
		Zeroes the stack below the caller's frame, where the frames of the compilation that just ended
		lie. hxcpp's collector scans the stack conservatively, and a wasm instance re-entered with callMain
		runs the next compilation over that same stretch of stack: a slot a new frame has not written yet
		still holds the old compilation's pointers, and kept its whole macro world alive (300 MB and more
		per OpenFL build). Only a wasm build re-enters main.
	**/
	public static function clearDeadStack():Void {
		#if emscripten
		untyped __cpp__("hxc_clear_stack((char *)emscripten_stack_get_current())");
		#end
	}

	/**
		exit for a wasm build: the exit unwinds to the host by a JavaScript exception, so no frame on the
		stack runs again, but the stack pointer stays where it was and the collector keeps scanning up to
		the highest stack top it has seen. The frames the exit abandons would hold the compilation for
		good; all of the stack is zeroed first, by a C function that keeps nothing there.
	**/
	public static function clearStackAndExit(code:Int):Void {
		#if emscripten
		untyped __cpp__("hxc_clear_stack_and_exit({0})", code);
		#end
	}
}
""" % (guarded([(class_conds[a], "@:access(%s)" % a) for a in accesses], ""), guarded(body, "\t\t"))
dest = ROOT + "hxc/core/ProcessState.hx"
old = open(dest, encoding="utf-8").read() if os.path.exists(dest) else None
if "--check" in sys.argv:
    print("in step" if old == out else "OUT OF STEP")
    sys.exit(0 if old == out else 1)
open(dest, "w", encoding="utf-8", newline="\n").write(out)
print("statics:", len(body), "classes:", len(accesses))
