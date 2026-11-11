#!/usr/bin/env bash
# Builds JoeClash's Android HL/C output with Haxe and with hxc and compares the two, file for file.
#   tools/hlc-joeclash.sh <hxc exe> <scratch dir>
# The build is the first section of $JOECLASH/build.android.hxml (default D:/_github/_JoeClash), everything
# before the first `--next`, with its `--hl` line replaced by `--hl <scratch>/<h|x>/main.c` and
# `-D no-compilation` added. It runs from JoeClash's folder, so `-cp src`, the local libs and res/ resolve,
# and writes nothing into JoeClash's bin/ (checked: nothing under bin/android is newer than the start, and
# `git status --short` is the same before and after).
# Haxe builds three times around hxc's build: Haxe -> hxc -> Haxe. Files where the two Haxe builds differ
# are Haxe's own nondeterminism (or library sources moving under the build); they are listed and left out
# of the comparison. Haxe runs without HAXE_STD_PATH; hxc gets HAXE_STD_PATH='C:\HaxeToolkit\haxe\std'
# (backslashes, as Haxe spells its own std path, so debug file names agree).
# Prints `files: <n> identical` and exits 0, or tools/hlc-compare.sh's report and exits 1.
set -u
hxc="${1:?usage: $0 <hxc exe> <scratch dir>}"
scratch="${2:?usage: $0 <hxc exe> <scratch dir>}"
here="$(cd "$(dirname "$0")" && pwd)"
jc="${JOECLASH:-D:/_github/_JoeClash}"
haxe="${HAXE:-haxe}"
case "$hxc" in */*) hxc="$(cd "$(dirname "$hxc")" && pwd)/$(basename "$hxc")" ;; esac
native() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }

mkdir -p "$scratch" || exit 2
scratch="$(cd "$scratch" && pwd)"
[ -f "$jc/build.android.hxml" ] || { echo "no $jc/build.android.hxml" >&2; exit 2; }

# The first section, with the --hl line swapped for the scratch directory's.
section() {
	awk -v out="$1" '
		/^[ \t]*--next([ \t]|$)/ { exit }
		/^[ \t]*--hl[ \t]/ { print "--hl " out; next }
		{ print }
		END { print "-D no-compilation" }
	' "$jc/build.android.hxml"
}
grep -qE '^[[:space:]]*--hl[[:space:]]' <(awk '/^[ \t]*--next([ \t]|$)/ { exit } { print }' "$jc/build.android.hxml") \
	|| { echo "the first section of build.android.hxml has no --hl line" >&2; exit 2; }

before="$(git -C "$jc" status --short)"
marker="$scratch/.start"
: > "$marker"

# build <label> <dir> <command...>: builds into <scratch>/<dir>/main.c and prints the time.
build() {
	local label="$1" dir="$2" hxml="$scratch/$2.hxml" code=0 t0 t1
	shift 2
	rm -rf "${scratch:?}/$dir"
	section "$(native "$scratch/$dir/main.c")" > "$hxml"
	t0=$(date +%s.%N)
	(cd "$jc" && "$@" "$(native "$hxml")") > "$scratch/$dir.log" 2>&1 || code=$?
	t1=$(date +%s.%N)
	rm -f "$hxml"
	printf '%s: %s s (exit %d)\n' "$label" "$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }')" "$code"
	if [ $code != 0 ] || [ ! -f "$scratch/$dir/main.c" ]; then
		echo "$label failed; its output:"
		sed 's/^/  /' "$scratch/$dir.log" | tail -40
		return 1
	fi
}

status=0
build "Haxe" h env -u HAXE_STD_PATH "$haxe" || status=2
[ $status = 0 ] && { mv "$scratch/h" "$scratch/h.first"; build "hxc" x env 'HAXE_STD_PATH=C:\HaxeToolkit\haxe\std' "$hxc" || status=2; }
[ $status = 0 ] && { build "Haxe again" h env -u HAXE_STD_PATH "$haxe" || status=2; }

after="$(git -C "$jc" status --short)"
if [ "$before" != "$after" ]; then
	echo "JoeClash's git status changed during the builds:"
	diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed 's/^/  /'
	status=2
fi
# bin/android is where the hxml's own --hl writes (bin/ as a whole is shared with other builds of JoeClash).
written="$( [ -d "$jc/bin/android" ] && find "$jc/bin/android" -newer "$marker" | head -5)"
if [ -n "$written" ]; then
	echo "written under $jc/bin/android during the builds:"
	printf '%s\n' "$written" | sed 's/^/  /'
	status=2
fi
rm -f "$marker"
[ $status = 0 ] || exit $status

# Haxe against itself: files that differ, or that only one Haxe build has, are left out of the comparison.
unstable="$( { diff -r -q "$scratch/h.first" "$scratch/h" 2>&1 || true; } \
	| sed -n -e "s|^Files $scratch/h.first/\(.*\) and .* differ\$|\1|p" \
		-e "s|^Only in $scratch/h.first\(/\?\)\(.*\): \(.*\)\$|\2\1\3|p" \
		-e "s|^Only in $scratch/h\(/\?\)\(.*\): \(.*\)\$|\2\1\3|p" | sort -u)"
if [ -n "$unstable" ]; then
	echo "Haxe differs from itself; left out of the comparison:"
	printf '%s\n' "$unstable" | sed 's/^/  /'
	while IFS= read -r f; do rm -rf "${scratch:?}/h/$f" "${scratch:?}/x/$f"; done <<< "$unstable"
else
	echo "Haxe matches itself"
fi
rm -rf "${scratch:?}/h.first"

n="$(cd "$scratch/h" && find . -type f | wc -l)"
report="$("$here/hlc-compare.sh" "$scratch/h" "$scratch/x")"
code=$?
if [ $code = 0 ]; then
	echo "files: $n identical"
else
	printf '%s\n' "$report"
fi
exit $code
