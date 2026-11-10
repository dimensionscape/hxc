#!/bin/sh
# Round-trips every .hl in <dir> through HlReader and HlWriter (see HlRoundTrip.hx); the dump text
# <name>.hlcode.txt beside a file, when there is one, is compared with HlDump's output too.
# Usage: tools/hl/roundtrip.sh <dir>
dir=${1:?usage: roundtrip.sh <dir>}
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root" || exit 1
status=0
for f in "$dir"/*.hl; do
	dump="${f%.hl}.hlcode.txt"
	echo "== $f"
	if [ -f "$dump" ]; then
		haxe -cp src -cp tools/hl --run HlRoundTrip "$f" "$dump" || status=1
	else
		haxe -cp src -cp tools/hl --run HlRoundTrip "$f" || status=1
	fi
done
exit $status
