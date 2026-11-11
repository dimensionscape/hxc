#!/usr/bin/env bash
# Compares two HL/C output directories (Haxe's and hxc's, as tests/hl/run.sh keeps them in h/ and x/).
#   tools/hlc-compare.sh <h dir> <x dir>
# Prints `only in Haxe: <path>` and `only in hxc: <path>` for each file only one side has, then, for the
# first file (in sorted order) that both have and that differs, its name and the first 40 lines of
# `diff -u`. Prints `identical` and exits 0 when the directories match; exits 1 otherwise.
set -u
h="${1:?usage: $0 <h dir> <x dir>}"
x="${2:?usage: $0 <h dir> <x dir>}"
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
while IFS= read -r f; do
	[ -z "$f" ] && continue
	if ! cmp -s "$h/$f" "$x/$f"; then
		echo "first differing file: ${f#./}"
		diff -u "$h/$f" "$x/$f" | head -40
		code=1
		break
	fi
done < <(comm -12 <(printf '%s\n' "$hl") <(printf '%s\n' "$xl"))
[ $code = 0 ] && echo identical
exit $code
