#!/usr/bin/env bash
# Builds hxc with MSVC profile-guided optimisation (Windows x64 only) and installs the result.
#   tools/pgo-build.sh [--out <exe>] <training> [<training> ...]
# A <training> is an .hxml to compile while the profile is recorded: `path/to/build.hxml` is compiled from its
# own directory, `dir::file.hxml` from <dir>. Each one runs as a normal compile, so it writes its usual output.
# Train on large builds for the targets that matter; the profile only helps the code those builds reach.
#
# Steps, all in bin/cpp/windows/x64/release/obj:
#   1. a release build with whole-program optimisation (HXCPP_OPTIMIZE_LINK), logged verbosely;
#   2. the program linked again from that log's link line with -GENPROFILE (hxc-pgi.exe, instrumented);
#   3. hxc-pgi.exe run on every <training> (several times slower than a normal compile);
#   4. the program linked once more with -USEPROFILE (hxc-pgo.exe);
#   5. hxc-pgo.exe copied to --out (default bin/hxc-windows-x64.exe).
# Measured on a large Heaps + HaxeUI HashLink build: 9% faster than the normal release build, where
# whole-program optimisation alone gave nothing. The output of a compile does not change.
#
# The next normal build recompiles everything, since the objects left behind are whole-program ones (the
# compile cache makes that quick). If the script stops before step 5, bin/hxc-windows-x64.exe is step 1's
# build: the same compiler, without the profile.
# Environment: what a normal build needs (AEDIFEX_ROOT where aedifex is not installed globally),
# HAXE_STD_PATH (default C:\HaxeToolkit\haxe\std, with backslashes as Haxe spells its own, since the path
# goes into the debug tables a training compile writes), HXCPP_COMPILE_THREADS (default 4: more can run cl
# out of heap on the largest files).
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
export HAXE_STD_PATH="${HAXE_STD_PATH:-C:\HaxeToolkit\haxe\std}"
export HXCPP_COMPILE_THREADS="${HXCPP_COMPILE_THREADS:-4}"
# Arguments such as -out:x and @file must reach link.exe as written.
export MSYS2_ARG_CONV_EXCL='*'
out="$root/bin/hxc-windows-x64.exe"
trainings=()
while [ $# -gt 0 ]; do
	case "$1" in
		--out) out="$2"; shift 2 ;;
		-h|--help) sed -n '2,7p' "$0"; exit 0 ;;
		*) trainings+=("$1"); shift ;;
	esac
done
[ ${#trainings[@]} -gt 0 ] || { echo "usage: $0 [--out <exe>] <training> [<training> ...]" >&2; exit 2; }
fail() { echo "pgo-build: $*" >&2; exit 1; }
for t in "${trainings[@]}"; do
	case "$t" in
		*::*) [ -d "${t%%::*}" ] || fail "no directory ${t%%::*}" ;;
		*) [ -f "$t" ] || fail "no file $t" ;;
	esac
done

obj="$root/bin/cpp/windows/x64/release/obj"
log="$obj/pgo-build.log"

echo "pgo-build: 1/5 whole-program build"
# The link line is only printed when the program is linked.
rm -f "$obj/ProgramMain.exe" "$obj/ProgramMain.exe.hash"
mkdir -p "$obj"
(cd "$root" && HXCPP_OPTIMIZE_LINK=1 HXCPP_VERBOSE=1 haxelib run aedifex build cpp . > "$log" 2>&1) || { tail -20 "$log" >&2; fail "the build failed (log: $log)"; }
plain="$obj/pgo-build.plain.log"
sed 's/\x1b\[[0-9;]*m//g' "$log" | tr -d '\r' > "$plain"
linkline="$(grep 'Link: ProgramMain.exe:' "$plain" | tail -1 | sed 's/^.*link\.exe //')"
[ -n "$linkline" ] || fail "no link line in $log"
case " $linkline " in *" -LTCG "*) ;; *) fail "the build did not use whole-program optimisation (is HXCPP_OPTIMIZE_LINK reaching hxcpp?)" ;; esac

# The compiler's environment, as the build printed it.
msvs() { grep "^  msvs $1=" "$plain" | head -1 | sed "s/^  msvs $1=//"; }
vcpath="$(msvs PATH)"
[ -n "$vcpath" ] || fail "no MSVC environment in $log"
export LIB="$(msvs LIB)" LIBPATH="$(msvs LIBPATH)"
unixpath=""
IFS=';' read -ra parts <<< "$vcpath"
for p in "${parts[@]}"; do [ -n "$p" ] && unixpath="$unixpath$(cygpath -u "$p"):"; done
export PATH="$unixpath$PATH"

relink() { # <exe name> <profile option>
	local line="${linkline/-out:ProgramMain.exe/-out:$1}"
	line="${line/ -LTCG / -LTCG $2 }"
	# No path on the line holds a space: they are relative to obj/ or in the compile cache.
	(cd "$obj" && link.exe $line) || fail "linking $1 failed"
}

echo "pgo-build: 2/5 instrumented link"
rm -f "$obj"/hxc.pgd "$obj"/hxc*.pgc "$obj/hxc-pgi.exe" "$obj/hxc-pgo.exe"
relink hxc-pgi.exe -GENPROFILE:PGD=hxc.pgd

echo "pgo-build: 3/5 training"
for t in "${trainings[@]}"; do
	case "$t" in
		*::*) dir="${t%%::*}"; file="${t#*::}" ;;
		*) dir="$(dirname "$t")"; file="$(basename "$t")" ;;
	esac
	echo "pgo-build:   $t"
	(cd "$dir" && "$obj/hxc-pgi.exe" "$file" > "$obj/pgo-train.log" 2>&1) || { tail -20 "$obj/pgo-train.log" >&2; fail "training on $t failed"; }
done
ls "$obj"/hxc*.pgc > /dev/null 2>&1 || fail "the training runs recorded no profile"

echo "pgo-build: 4/5 optimised link"
relink hxc-pgo.exe -USEPROFILE:PGD=hxc.pgd

echo "pgo-build: 5/5 install"
cp "$obj/hxc-pgo.exe" "$out" || fail "cannot write $out (is it running?)"
echo "pgo-build: $out"
