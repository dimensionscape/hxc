#!/usr/bin/env bash
# Compiles a case with Haxe and with hxc (both -D dump) and prints where their dumps first differ.
#   tools/hl-compare.sh <case dir> [extra args...]
# <case dir> holds the case's sources (P.hx, ...); they are copied to <case dir>/.hl-compare/src, where
# Haxe and then hxc compile with `-cp . --main P --hl out.hl -D hl_no_opt -D dump` and the extra args (one
# directory, so that paths baked in with -D absolute-path agree); each one's out.hl and dump/ are moved to
# .hl-compare/h (Haxe) and .hl-compare/x (hxc).
# It then compares h/dump/hlcode.txt with x/dump/hlcode.txt table by table (strings, bytes, ints, floats,
# globals, natives), then the functions by their `; file:line (Class.method)` label, with `@N` and `fun@N`
# resolved to what the tables give so that a function can match while the numbering differs, and prints the
# first differing table entry, `functions: <same>/<total> identical` and the first differing function as two
# columns. h/dump/hl/*.dump (the typed AST) is compared too: a difference there is a typer or filter bug,
# not a generator one. Exit 1 when anything differs.
# Environment: HXC (default bin/hxc-windows-x64.exe), HAXE (default haxe), HAXE_STD_PATH for hxc (default
# C:/HaxeToolkit/haxe/std when that exists), HXC_ARGS: arguments for the second compile only, HL_MAIN: the
# main class (default P; a case with `@ pack.Module` gives that module and keeps its file at pack/Module.hx).
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
case="${1:?usage: $0 <case dir> [extra args...]}"
shift
case="$(cd "$case" && pwd)"
hxc="${HXC:-$root/bin/hxc-windows-x64.exe}"
haxe="${HAXE:-haxe}"
if [ -z "${HAXE_STD_PATH:-}" ] && [ -d C:/HaxeToolkit/haxe/std ]; then export HAXE_STD_PATH=C:/HaxeToolkit/haxe/std; fi
native() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }

work="$case/.hl-compare"
rm -rf "$work"
mkdir -p "$work/src" "$work/h" "$work/x"
for f in "$case"/*; do
	[ "$f" = "$work" ] && continue
	cp -R "$f" "$work/src/"
done
# Moves src/out.hl and src/dump to $1.
collect() {
	[ -f "$work/src/out.hl" ] && mv "$work/src/out.hl" "$work/$1/"
	[ -d "$work/src/dump" ] && mv "$work/src/dump" "$work/$1/"
}
args=(-cp . --main "${HL_MAIN:-P}" --hl out.hl -D hl_no_opt -D dump "$@")
"$haxe" --cwd "$(native "$work/src")" "${args[@]}" > "$work/h.log" 2>&1 || { echo "Haxe failed:"; cat "$work/h.log"; exit 2; }
collect h
# shellcheck disable=SC2086 # HXC_ARGS is a list
"$hxc" --cwd "$(native "$work/src")" "${args[@]}" ${HXC_ARGS:-} > "$work/x.log" 2>&1 || { echo "hxc failed:"; cat "$work/x.log"; }
collect x
cd "$root" || exit 2
haxe -cp tools/hl --run HlCompare "$(native "$work/h")" "$(native "$work/x")"
