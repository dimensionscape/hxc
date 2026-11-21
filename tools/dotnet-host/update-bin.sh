#!/usr/bin/env bash
# Rebuilds the .NET-hosted hxc from this checkout's source and puts it in bin/, where `haxelib run hxc` finds it
# (Run.hx prefers bin/hxc.exe over the native bin/hxc-windows-x64.exe). Windows only, like build.sh.
#
#   update-bin.sh [--bootstrap] [hxc]
#
# [hxc]        the compiler that does the build. Default: whichever of bin/'s two compilers is newer, the .NET one
#              (run from a copy, since bin/hxc.dll may be in use) or the native one.
# --bootstrap  build a second time with the first result and check the two hxc.dll files are identical. Use it
#              after a change to the .NET generator, which the first build only runs, not contains.
#
# The build happens outside the repository, in HXC_DOTNET_HOST_WORK (default %LOCALAPPDATA%\hxc\dotnet-host),
# which also keeps PCRE2 and zlib built between runs. HAXE_STD_PATH defaults to the std of the haxe on PATH.
# Files in bin/ that a running compile holds are renamed aside rather than overwritten.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
bin="$root/bin"
files="hxc.exe hxc.dll hxc.runtimeconfig.json HxcHostNative.dll pcre2-8.dll hxczlib.dll"

bootstrap=0
if [ "$1" = "--bootstrap" ]; then bootstrap=1; shift; fi
hxc="$1"

if [ -z "${HAXE_STD_PATH:-}" ]; then
	haxe="$(command -v haxe)" || { echo "update-bin.sh: no haxe on PATH; set HAXE_STD_PATH" >&2; exit 1; }
	export HAXE_STD_PATH="$(cygpath -w "$(dirname "$haxe")/std")"
fi

work="${HXC_DOTNET_HOST_WORK:-$(cygpath -u "${LOCALAPPDATA:?LOCALAPPDATA is not set}")/hxc/dotnet-host}"
mkdir -p "$work"; work="$(cd "$work" && pwd)"
case "$work/" in "$root"/*) echo "update-bin.sh: the work folder must be outside the repository" >&2; exit 1;; esac

copy_set() { # <from> <to>
	mkdir -p "$2"
	for f in $files; do cp "$1/$f" "$2/$f"; done
}

if [ -z "$hxc" ]; then
	native="$bin/hxc-windows-x64.exe"
	if [ -f "$bin/hxc.dll" ] && { [ ! -f "$native" ] || [ "$bin/hxc.dll" -nt "$native" ]; }; then
		rm -rf "$work/builder"; copy_set "$bin" "$work/builder"
		hxc="$work/builder/hxc.exe"
	elif [ -f "$native" ]; then
		hxc="$native"
	else
		echo "update-bin.sh: no compiler in $bin to build with; pass one" >&2; exit 1
	fi
fi
hxc="$(cd "$(dirname "$hxc")" && pwd)/$(basename "$hxc")"
echo "building with $hxc"

"$here/build.sh" "$hxc" "$work/out"
if [ "$bootstrap" = 1 ]; then
	rm -rf "$work/stage1"; copy_set "$work/out" "$work/stage1"
	"$here/build.sh" "$work/stage1/hxc.exe" "$work/out"
	cmp "$work/stage1/hxc.dll" "$work/out/hxc.dll" || { echo "update-bin.sh: the second build differs from the first; bin/ left as it was" >&2; exit 1; }
fi

for f in $files; do
	rm -f "$bin/$f.old" 2>/dev/null || true
	[ -f "$bin/$f" ] && mv "$bin/$f" "$bin/$f.old"
	cp "$work/out/$f" "$bin/$f"
	rm -f "$bin/$f.old" 2>/dev/null || true
done
echo "updated $bin/hxc.exe ($(git -C "$root" rev-parse --short HEAD)$(git -C "$root" diff --quiet HEAD -- src || echo ', with uncommitted changes in src'))"
