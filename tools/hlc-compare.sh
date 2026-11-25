#!/usr/bin/env bash
# Compares two HL/C output directories (Haxe's and hxc's, as tests/hl/run.sh keeps them in h/ and x/).
#   tools/hlc-compare.sh <h dir> <x dir>
# Prints `only in Haxe: <path>` and `only in hxc: <path>` for each file only one side has, then, for the
# first file (in sorted order) that both have and that differs, its name and the first 40 lines of
# `diff -u`. Prints `identical` and exits 0 when the directories match; exits 1 otherwise.
#   tools/hlc-compare.sh --list <a dir> <b dir>
# Prints every file that only one side has or that differs, one relative path per line in sorted order;
# exits 0 when there are none, 1 otherwise.
set -u
list=0
if [ "${1:-}" = "--list" ]; then list=1; shift; fi
h="${1:?usage: $0 [--list] <h dir> <x dir>}"
x="${2:?usage: $0 [--list] <h dir> <x dir>}"
h="${h%/}"; x="${x%/}"
[ -d "$h" ] && [ -d "$x" ] || { echo "both arguments must be directories" >&2; exit 2; }
hl="$(cd "$h" && find . -type f | sort)"
xl="$(cd "$x" && find . -type f | sort)"
common() { comm -12 <(printf '%s\n' "$hl") <(printf '%s\n' "$xl"); }

# The files both sides have that differ, as ./path in sorted order. One `diff -r -q` pass finds them (a cmp
# per file is minutes on JoeClash's 2800 files). diff quotes a name with spaces or other awkward characters
# (`Files 'h/a b.c' and 'x/a b.c' differ`); when any of its lines is not one this parses, or diff fails,
# every common file goes through cmp instead.
differing() {
	local out dcode=0 parsed="" fallback=0 line f
	out="$(diff -r -q "$h" "$x" 2>&1)" || dcode=$?
	[ $dcode = 0 ] && return 0
	[ $dcode = 1 ] || fallback=1
	while IFS= read -r line; do
		case "$line" in
			"Files $h/"*" and $x/"*" differ")
				line="${line#"Files $h/"}"
				parsed+="./${line%% and "$x/"*}"$'\n' ;;
			"Only in $h"*": "* | "Only in $x"*": "*) ;;
			"") ;;
			*) fallback=1 ;;
		esac
	done <<< "$out"
	if [ $fallback = 1 ]; then
		while IFS= read -r f; do
			[ -n "$f" ] && ! cmp -s "$h/$f" "$x/$f" && printf '%s\n' "$f"
		done < <(common)
	else
		printf '%s' "$parsed" | sort
	fi
	return 0
}

if [ $list = 1 ]; then
	all="$( { comm -3 <(printf '%s\n' "$hl") <(printf '%s\n' "$xl") | sed 's/^\t//'; differing; } | sed -e '/^$/d' -e 's|^\./||' | sort -u)"
	[ -z "$all" ] && exit 0
	printf '%s\n' "$all"
	exit 1
fi

code=0
while IFS= read -r f; do
	[ -z "$f" ] && continue
	echo "only in Haxe: ${f#./}"; code=1
done < <(comm -23 <(printf '%s\n' "$hl") <(printf '%s\n' "$xl"))
while IFS= read -r f; do
	[ -z "$f" ] && continue
	echo "only in hxc: ${f#./}"; code=1
done < <(comm -13 <(printf '%s\n' "$hl") <(printf '%s\n' "$xl"))
first="$(differing | head -1)"
if [ -n "$first" ]; then
	echo "first differing file: ${first#./}"
	diff -u "$h/$first" "$x/$first" | head -40
	code=1
fi
[ $code = 0 ] && echo identical
exit $code
