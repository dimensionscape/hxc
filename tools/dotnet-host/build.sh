#!/usr/bin/env bash
# Builds hxc as a .NET program: `build.sh <hxc> <out-dir> [extra hxc arguments]`. README.md beside this
# file says what the result is for and what it does not do. <hxc> is the compiler that does the build: the
# native one, or an earlier result of this script, which gives the same bytes.
#
#   <out-dir>/hxc.exe                          the launcher (needs .NET 10 installed)
#   <out-dir>/hxc.dll                          the compiler
#   <out-dir>/HxcHostNative.dll, pcre2-8.dll   what a macro's EReg runs on
#
# Needs the .NET SDK, and MSVC for pcre2-8.dll (built once, from the PCRE2 source in the hxcpp checkout
# HXCPP points at; default: `haxelib libpath hxcpp`). Windows only for now.
#
# The assembly is precompiled (ReadyToRun), so a small build does not wait for the JIT, and
# hxc.runtimeconfig.json carries the runtime settings a compile is fastest with: server GC, no dynamic PGO,
# and methods counted for tier-up from the start. Without them a large build takes about twice as long.
# eval.luv and SSL sockets in macros are not available on this host.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
hxc="$1"; out="$2"
[ -n "$hxc" ] && [ -n "$out" ] || { echo "usage: build.sh <hxc> <out-dir> [hxc arguments]" >&2; exit 2; }
shift 2
mkdir -p "$out"; out="$(cd "$out" && pwd)"
obj="$out/obj"; mkdir -p "$obj"
vs="$("/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe" -latest -products '*' -property installationPath | tr -d '\r')"

if [ ! -f "$obj/pcre2-8.dll" ]; then
	hxcpp="${HXCPP:-$(haxelib libpath hxcpp | tr -d '\r')}"
	pcre="$(cygpath -w "$hxcpp/project/thirdparty/pcre2-10.42/src")"
	srcs=""
	for f in auto_possess chartables compile config context convert dfa_match error extuni find_bracket jit_compile maketables \
		match match_data newline ord2utf pattern_info script_run serialize string_utils study substitute substring tables ucd valid_utf xclass; do
		srcs="$srcs \"$pcre\\pcre2_$f.c\""
	done
	mkdir -p "$obj/pcre2"
	{
		echo '@echo off'
		echo "call \"$(cygpath -w "$vs")\\VC\\Auxiliary\\Build\\vcvars64.bat\" >nul 2>&1 || exit /b 1"
		echo "cd /d \"$(cygpath -w "$obj/pcre2")\" || exit /b 1"
		echo "cl /nologo /O2 /MT /LD /DHAVE_CONFIG_H /DSUPPORT_UNICODE /DPCRE2_CODE_UNIT_WIDTH=8 /DSUPPORT_PCRE2_8 /I\"$pcre\" $srcs /Fe:..\\pcre2-8.dll >build.log 2>&1 || (type build.log & exit /b 1)"
	} > "$obj/pcre2/build.bat"
	cmd //c "$(cygpath -w "$obj/pcre2/build.bat")"
fi

# Built from a copy, so the SDK's obj folder stays out of the source tree.
rm -rf "$obj/shimsrc"; mkdir -p "$obj/shimsrc"; cp "$here"/*.csproj "$here"/*.cs "$obj/shimsrc/"
dotnet build "$obj/shimsrc/HxcHostNative.csproj" -c Release -o "$obj/shim" --nologo -v q >"$obj/shim.log" 2>&1 || { cat "$obj/shim.log" >&2; exit 1; }

# .NET seeds String.GetHashCode afresh in each process and the std's StringMap walks its keys in hash order:
# the compiler gets a copy of that StringMap hashing with hxc.core.StableStringHash, so that it does the same
# thing in every run.
std="${HAXE_STD_PATH:?HAXE_STD_PATH must be set}"
rm -rf "$obj/std"; mkdir -p "$obj/std/haxe/ds"
# The copy is on the class path of the build's own macros too, which must keep the interpreter's StringMap:
# that one goes in the `#if macro` half.
{
	echo '#if macro'
	cat "$std/haxe/ds/StringMap.hx"
	echo '#else'
	sed 's/untyped s\.GetHashCode()/hxc.core.StableStringHash.hash(s)/' "$std/cs/_std/haxe/ds/StringMap.hx"
	echo '#end'
} > "$obj/std/haxe/ds/StringMap.hx"
grep -q 'StableStringHash' "$obj/std/haxe/ds/StringMap.hx" || { echo "build.sh: the std's StringMap has no GetHashCode call to replace" >&2; exit 1; }

rm -rf "$obj/hxc"
(cd "$obj" && "$hxc" -cp "$(cygpath -w "$obj/std")" -cp "$(cygpath -w "$root/src")" -main hxc.Compiler --dotnet hxc -D dll-name=hxc -D dotnet-exe=launcher -D dotnet-r2r \
	-D no_map_cache -D dotnet-no-exception-stack -D hxc_pcre2_netlib --net-lib "$(cygpath -w "$obj/shim/HxcHostNative.dll")" "$@")

cp "$obj/hxc/hxc.dll" "$obj/hxc/hxc.exe" "$obj/shim/HxcHostNative.dll" "$obj/pcre2-8.dll" "$out/"
tfm="$(sed -n 's/.*"tfm": *"\([^"]*\)".*/\1/p' "$obj/hxc/hxc.runtimeconfig.json")"
ver="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$obj/hxc/hxc.runtimeconfig.json")"
cat > "$out/hxc.runtimeconfig.json" <<JSON
{
  "runtimeOptions": {
    "tfm": "$tfm",
    "framework": {
      "name": "Microsoft.NETCore.App",
      "version": "$ver"
    },
    "configProperties": {
      "System.GC.Server": true,
      "System.GC.Concurrent": false,
      "System.Runtime.TieredPGO": false,
      "System.Runtime.TieredCompilation.CallCountingDelayMs": 0
    }
  }
}
JSON
# The parser and typer recurse deeply: give the main thread 256 MB of stack.
editbin="$(ls "$vs"/VC/Tools/MSVC/*/bin/Hostx64/x64/editbin.exe | tail -1)"
"$editbin" //NOLOGO //STACK:268435456 "$(cygpath -w "$out/hxc.exe")" >/dev/null
echo "built $out/hxc.exe"
