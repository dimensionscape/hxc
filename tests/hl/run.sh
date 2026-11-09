#!/usr/bin/env bash
# Runs the HashLink generator's cases in tests/cases/hl-output/cases.hx.txt.
#   tests/hl/run.sh --compiler <hxc> [--haxe <haxe>] [--hl <hl.exe>] [--std <dir>] [--case <pattern>] [-j <jobs>]
# A case is `--- name [@ pack.Module] [+ extra compiler args]`, its source (module P unless `@` names another,
# written at that module's path and given to --main), `===` and nothing after it (the
# expected result is Haxe's own). Each case is compiled with the family's arguments (family.json, less the
# digest macro) in one directory, src/, by Haxe and then by hxc twice (one directory, so that paths baked in
# with -D absolute-path agree); each out.hl is moved to h.hl, x.hl and y.hl. x.hl must be byte-identical to
# y.hl (else `nondeterministic`) and to h.hl (else `differs from Haxe; see tools/hl-compare.sh`), and hl must
# print the same and exit the same running h.hl and x.hl in src/ (else `runs differently`).
# --case runs the cases whose names match it, a shell pattern like `trace-*`. Cases run -j at a time
# (default $HXC_TEST_JOBS, or 4) and report in case order. Case directories go under $HXC_TEST_TMP, by
# default tests/hl/tmp (gitignored), and are kept for a failed case.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
compiler=""
haxe="haxe"
hl="${HL:-hl}"
std=""
only=""
njobs="${HXC_TEST_JOBS:-4}"
usage="usage: $0 --compiler <hxc> [--haxe <haxe>] [--hl <hl.exe>] [--std <dir>] [--case <pattern>] [-j <jobs>]"
while [ $# -gt 0 ]; do
	case "$1" in
		--compiler) compiler="$2"; shift 2 ;;
		--haxe) haxe="$2"; shift 2 ;;
		--hl) hl="$2"; shift 2 ;;
		--std) std="$2"; shift 2 ;;
		--case) only="$2"; shift 2 ;;
		-j | --jobs) njobs="$2"; shift 2 ;;
		-j*) njobs="${1#-j}"; shift ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done
if [ -z "$compiler" ]; then
	echo "$usage" >&2
	exit 2
fi
case "$njobs" in
	"" | *[!0-9]* | 0*) echo "-j needs a positive number of jobs, not '$njobs'" >&2; exit 2 ;;
esac
# hxc as an absolute path, since cases run in other directories.
case "$compiler" in */*) compiler="$(cd "$(dirname "$compiler")" && pwd)/$(basename "$compiler")" ;; esac
if [ -n "$std" ]; then export HAXE_STD_PATH="$std"; fi

# hl must run: without it every `runs differently` check would compare two identical failures.
if ! "$hl" --version > /dev/null 2>&1; then
	echo "cannot run HashLink ('$hl'); give --hl <hl.exe> or set \$HL" >&2
	exit 2
fi

tmproot="${HXC_TEST_TMP:-$here/tmp}"
mkdir -p "$tmproot" || exit 1
tmproot="$(cd "$tmproot" && pwd)"
resdir="$(mktemp -d "$tmproot/results.XXXXXX")" || exit 1
trap 'rm -rf "$resdir"' EXIT

# A native Windows path when cygpath exists (Haxe and hxc are Windows programs).
native() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }

# The family's arguments without the digest macro: HlDigest is only for the conformance harness.
cargs=(-cp . --hl out.hl -D hl_no_opt)

# Runs hl on $2 in directory $1 for at most 60 seconds; sets $ran to its output and `[exit N]`.
run_hl() {
	local code=0
	ran="$(cd "$1" && exec timeout -k 5 60 "$hl" "$2" 2>&1)" || code=$?
	ran="$ran"$'\n'"[exit $code]"
	ran="${ran//$'\r'/}"
}

# Runs case $1 (extra args $2, source $3, module $5) in directory $4 and prints its report line(s).
run_case() {
	local name="$1" extra="$2" source="$3" d="$4" module="$5" problem="" hcode=0 xcode=0 ycode=0 hout xout
	local file="$d/src/${module//.//}.hx" src="$(native "$d/src")"
	mkdir -p "$(dirname "$file")"
	printf '%s\n' "$source" > "$file"
	set -f
	hout="$("$haxe" --cwd "$src" "${cargs[@]}" --main "$module" $extra 2>&1)" || hcode=$?
	[ -f "$d/src/out.hl" ] && mv "$d/src/out.hl" "$d/h.hl"
	xout="$("$compiler" --cwd "$src" "${cargs[@]}" --main "$module" $extra 2>&1)" || xcode=$?
	[ -f "$d/src/out.hl" ] && mv "$d/src/out.hl" "$d/x.hl"
	"$compiler" --cwd "$src" "${cargs[@]}" --main "$module" $extra > /dev/null 2>&1 || ycode=$?
	[ -f "$d/src/out.hl" ] && mv "$d/src/out.hl" "$d/y.hl"
	set +f
	if [ $hcode != 0 ] || [ ! -f "$d/h.hl" ]; then
		problem="Haxe could not compile the case (exit $hcode): $hout"
	elif [ ! -f "$d/x.hl" ]; then
		problem="x.hl missing (hxc exit $xcode)${xout:+: $xout}"
	elif [ ! -f "$d/y.hl" ]; then
		problem="y.hl missing (hxc exit $ycode on the second compile)"
	elif ! cmp -s "$d/x.hl" "$d/y.hl"; then
		problem="nondeterministic: x.hl differs from y.hl"
	elif ! cmp -s "$d/x.hl" "$d/h.hl"; then
		problem="differs from Haxe; see tools/hl-compare.sh"
	else
		run_hl "$d/src" ../h.hl
		hout="$ran"
		run_hl "$d/src" ../x.hl
		if [ "$ran" != "$hout" ]; then
			problem="runs differently: Haxe's build printed '$hout', hxc's '$ran'"
		fi
	fi
	if [ -z "$problem" ]; then
		echo "ok $name"
		rm -rf "$d"
	else
		echo "FAIL $name"
		echo "$problem" | sed 's/^/  /'
		echo "  (kept in $d)"
		return 1
	fi
}

# Reads the cases: `# ` lines are comments.
c_name=(); c_extra=(); c_source=(); c_module=()
name=""; extra=""; source=""; module=P; inexpect=0
flush() {
	# shellcheck disable=SC2053 # --case is a pattern
	if [ -n "$name" ] && { [ -z "$only" ] || [[ $name == $only ]]; }; then
		c_name+=("$name"); c_extra+=("$extra"); c_source+=("$source"); c_module+=("$module")
	fi
	name=""
}
while IFS= read -r line || [ -n "$line" ]; do
	line="${line%$'\r'}"
	if [ "$line" = "#" ] || [ "${line#\# }" != "$line" ]; then continue; fi
	if [ "${line#---}" != "$line" ]; then
		flush
		head="${line#---}"
		extra=""
		case "$head" in *" + "*) extra="${head#* + }"; head="${head%% + *}" ;; esac
		module=P
		case "$head" in *"@"*) module="${head#*@}"; module="${module// /}"; head="${head%%@*}" ;; esac
		set -f; set -- $head; set +f
		name="$1"
		source=""
		inexpect=0
	elif [ -z "$name" ]; then
		continue
	elif [ "${line#===}" != "$line" ]; then
		inexpect=1
	elif [ $inexpect = 0 ]; then
		source="$source$line"$'\n'
	fi
done < "$root/tests/cases/hl-output/cases.hx.txt"
flush

if [ ${#c_name[@]} = 0 ]; then
	echo "no case matched" >&2
	exit 1
fi

# Each case runs in a subshell; the reports print in case order.
running=0
for i in "${!c_name[@]}"; do
	while [ $running -ge "$njobs" ]; do wait -n; running=$((running - 1)); done
	(
		run_case "${c_name[$i]}" "${c_extra[$i]}" "${c_source[$i]}" "$tmproot/c$i.$$" "${c_module[$i]}" > "$resdir/$i.out" 2>&1
		echo $? > "$resdir/$i.res"
	) &
	running=$((running + 1))
done
wait
failed=0
for i in "${!c_name[@]}"; do
	cat "$resdir/$i.out"
	read -r code < "$resdir/$i.res"
	[ "$code" = 0 ] || failed=$((failed + 1))
done
if [ $failed != 0 ]; then
	echo "$failed of ${#c_name[@]} cases failed"
	exit 1
fi
echo "all ${#c_name[@]} cases passed"
