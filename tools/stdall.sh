#!/bin/sh
# stdall.sh <hxc.exe> <out dir>: every hxcs standard-library class compiled with -dce no and -D dotnet-stub-report,
# so the report lists each std method still stubbed and each class left out, whether or not an app reaches it.
# sys.db and cs.db are left out: hxcs's AdoNet needs System.Data externs (IDataReader, then IXmlSerializable and
# Task_1 through further --net-libs) that this std does not type. -D unsafe for cs.Pointer. No private names.
HXC=${1:?hxc}; OUT=${2:?out dir}
mkdir -p "$OUT"
printf 'class P { static function main() {} }\n' > "$OUT/P.hx"
cd "$OUT" || exit 1
HAXE_STD_PATH=${HAXE_STD_PATH:-C:/HaxeToolkit/haxe/std} timeout 900 "$HXC" -cp . -main P --cs h -D dotnet -D dotnet-stub-report \
  -D unsafe -dce no \
  --macro "include('sys', true, ['sys.db'])" \
  --macro "include('haxe', true, ['haxe.macro', 'haxe.display', 'haxe.atomic', 'haxe.hxb'])" \
  --macro "include('cs', true, ['cs._std', 'cs.db'])" > stdall.log 2>&1
echo "exit $?; $(grep -c '^stubbed' stdall.log) stubbed, $(grep -c '^skipped' stdall.log) skipped, $(grep -c 'dotnet: ' stdall.log) errors"
grep -E '^(stubbed|skipped|ignored) ' stdall.log
