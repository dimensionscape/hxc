#!/usr/bin/env bash
# Compiles Haxe's own unit suite (haxe-conformance/tests/unit) to HashLink with Haxe and with hxc (both
# -D dump), compares the two dumps with HlCompare --all, and runs both unit.hl on hl.exe.
#   tools/hl-unit.sh [<haxe-conformance dir>]      (default D:/_github/haxe-conformance)
# Work happens in <hxc>/.hl-unit/ (gitignored): compile.hxml is compile-hl.hxml minus its `hl-check` lines;
# h/ (Haxe) and x/ (hxc) each get unit.hl and dump/; h.run.txt and x.run.txt are what hl.exe printed.
# The compiles run in <dir>/tests/unit, which is left as it was (no bin/unit.hl, no dump/, and no bin/ unless
# it was there before). It builds against the installed utest, not the pin in Haxe's CI, so both runs end in
# utest 2's `Null access` crash (see tests/hl/README.md); `corpus unit-hl` is the gate that uses the pin.
# The output is HlCompare's (with one `differs: <label>` line per differing function), then `runs: same` or
# `runs: differ` (the `Generated at:` lines are dropped before comparing).
# Environment: HXC (default bin/hxc-windows-x64.exe), HAXE (default haxe), HL (default
# C:/SDKs/hashlink/hl.exe), HAXE_STD_PATH (default C:/HaxeToolkit/haxe/std, exported for both compilers so
# that both write the same std path into their debug tables).
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
conf="${1:-D:/_github/haxe-conformance}"
hxc="${HXC:-$root/bin/hxc-windows-x64.exe}"
haxe="${HAXE:-haxe}"
hl="${HL:-C:/SDKs/hashlink/hl.exe}"
export HAXE_STD_PATH="${HAXE_STD_PATH:-C:/HaxeToolkit/haxe/std}"
native() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }

[ -f "$hl" ] && [ -x "$hl" ] || { echo "hl.exe not found: $hl" >&2; exit 2; }
unit="$conf/tests/unit"
[ -f "$unit/compile-hl.hxml" ] || { echo "no $unit/compile-hl.hxml" >&2; exit 2; }
unitbin_existed=0; [ -e "$unit/bin" ] && unitbin_existed=1
trap '[ $unitbin_existed = 0 ] && rmdir "$unit/bin" 2>/dev/null' EXIT
work="$root/.hl-unit"
rm -rf "$work"
mkdir -p "$work/h" "$work/x"

# compile-hl.hxml without its hl-check lines (the last line may lack a newline)
{ grep -v 'hl-check' "$unit/compile-hl.hxml"; echo; } | tr -d '\r' > "$work/compile.hxml"
hxml="$(native "$work/compile.hxml")"

# Compiles with compiler $2 into $work/$1.
build() {
	local side="$1" compiler="$2" code=0
	rm -rf "$unit/bin/unit.hl" "$unit/dump"
	"$compiler" --cwd "$(native "$unit")" "$hxml" -D dump > "$work/$side.log" 2>&1 || code=$?
	[ -f "$unit/bin/unit.hl" ] && mv "$unit/bin/unit.hl" "$work/$side/"
	[ -d "$unit/dump" ] && mv "$unit/dump" "$work/$side/"
	rm -rf "$unit/bin/unit.hl" "$unit/dump"
	if [ $code != 0 ] || [ ! -f "$work/$side/unit.hl" ]; then
		echo "$compiler failed (exit $code):"
		cat "$work/$side.log"
		exit 2
	fi
}
build h "$haxe"
build x "$hxc"

cd "$root" || exit 2
haxe -cp tools/hl --run HlCompare --all "$(native "$work/h")" "$(native "$work/x")"
code=$?

for side in h x; do
	( cd "$work/$side" && timeout -k 5 300 "$hl" unit.hl > "$work/$side.run.txt" 2>&1 )
	rc=$?
	echo "[exit $rc]" >> "$work/$side.run.txt"
	if [ $rc = 126 ] || [ $rc = 127 ]; then echo "could not launch $hl (exit $rc)" >&2; exit 2; fi
done
if cmp -s <(grep -v 'Generated at:' "$work/h.run.txt" | tr -d '\r') <(grep -v 'Generated at:' "$work/x.run.txt" | tr -d '\r'); then
	echo "runs: same"
else
	echo "runs: differ (see .hl-unit/h.run.txt and x.run.txt)"
	code=1
fi
exit $code
