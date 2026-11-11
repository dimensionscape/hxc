#!/usr/bin/env bash
# Compares two HL/C output directories (Haxe's and hxc's, as tests/hl/run.sh keeps them in h/ and x/).
#   tools/hlc-compare.sh <h dir> <x dir>
# Prints `only in Haxe: <path>` and `only in hxc: <path>` for each file only one side has, then, for the
# first file (in sorted order) that both have and that differs, its name and the first 40 lines of
# `diff -u`. Prints `identical` and exits 0 when the directories match; exits 1 otherwise.
set -u
h="${1:?usage: $0 <h dir> <x dir>}"
x="${2:?usage: $0 <h dir> <x dir>}"
h="${h%/}"; x="${x%/}"
[ -d "$h" ] && [ -d "$x" ] || { echo "both arguments must be directories" >&2; exit 2; }
hl="$(cd "$h" && find . -type f | sort)"
xl="$(cd "$x" && find . -type f | sort)"
code=0
while IFS= read -r f; do
	[ -z "$f" ] && continue
	echo "only in Haxe: ${f#./}"; code=1
done < <(comm -23 <(printf '%s\n' "$hl") <(printf '%s\n' "$xl"))
while IFS= read -r f; do
	[ -z "$f" ] && continue
	echo "only in hxc: ${f#./}"; code=1
done < <(comm -13 <(printf '%s\n' "$hl") <(printf '%s\n' "$xl"))
# One `diff -r -q` pass finds the differing files (a cmp per file is minutes on JoeClash's 2800 files).
first="$(diff -r -q "$h" "$x" 2>/dev/null | while IFS= read -r line; do
	case "$line" in "Files $h/"*" differ") ;; *) continue ;; esac
	line="${line#"Files $h/"}"
	printf './%s\n' "${line%% and "$x/"*}"
done | sort | head -1)"
if [ -n "$first" ]; then
	echo "first differing file: ${first#./}"
	diff -u "$h/$first" "$x/$first" | head -40
	code=1
fi
[ $code = 0 ] && echo identical
exit $code
