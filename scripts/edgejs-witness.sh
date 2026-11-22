#!/bin/sh
cd /workspace/fx/fx || exit 1
P=${EDGE_SPIKE_DIR:-/workspace/tmp/fx/edge}; export P
SRC=${EDGEJS_SRC:-/workspace/tmp/gm/edgejs/src}
BUILD=${EDGEJS_BUILD:?EDGEJS_BUILD names the edgejs cmake build directory}
BASE=${FX_BASE_BIN:?FX_BASE_BIN names the default fx binary to compare against}
fails=0
check() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (got $2, want $3)"; fails=$((fails+1)); fi; }
mkdir -p "$P/lib" "$P/js" "$P/prefix"
rm -f "$P/lib"/*
flags=$(find "$BUILD" -path '*edge_cli.dir/flags.make' | head -1)
[ -n "$flags" ] || { echo "no edge_cli flags.make under $BUILD"; echo "EDGE_DONE 1"; exit 1; }
cxx_flags=$(sed -n 's/^CXX_FLAGS = //p;s/^CXX_DEFINES = //p;s/^CXX_INCLUDES = //p' "$flags" | tr '\n' ' ')
eval "g++ -c $cxx_flags native/edgejs/fx_edge.cc -o $P/lib/fx_edge.o" || { echo "shim compile failed"; echo "EDGE_DONE 1"; exit 1; }
find "$BUILD" -name '*.a' -exec ln -sf {} "$P/lib/" \;
echo "LIBS $(ls "$P/lib" | wc -l)"
timeout 2400 zig build install -Dcpu=baseline -Doptimize=ReleaseSafe -Dupdate-channel=stable -Dedgejs="$P/lib" --prefix "$P/prefix" --cache-dir "$P/cache" > "$P/build.out" 2>&1 & c=$!; echo "CHILD edge_build pid=$c"; wait $c; rc=$?
echo "RC edge_build = $rc"; grep -a 'error' "$P/build.out" | head -8 | cut -c1-220
[ $rc -eq 0 ] || { echo "EDGE_DONE 1"; exit 1; }
FX=$P/prefix/bin/fx
echo "SIZE before=$(stat -c %s "$BASE") after=$(stat -c %s "$FX")"
printf '%s\n' "console.log(fxHost.call('fs_write', JSON.stringify({ path: '$P/js/verb.txt', content: 'written' })))" > "$P/js/verb.mjs"
printf '%s\n' "import('node:child_process').then((m) => console.log('child_process loaded ' + typeof m.spawnSync), (e) => console.log(e.message))" > "$P/js/spawn.mjs"
printf '%s\n' "import('node:fs').then((m) => { m.writeFileSync('$P/js/fs.txt', 'node'); console.log('fs wrote') }, (e) => console.log(e.message))" > "$P/js/fs.mjs"
run() { timeout 120 "$FX" run-code --engine edge --file "$1" --permission-mode "$2" 2>&1 | tail -1; }
check "verb fs_write refused by the Zig gate in ask" "$(run "$P/js/verb.mjs" ask | grep -o EFX_PERMISSION_DENIED)" EFX_PERMISSION_DENIED
check "red: the same verb is admitted in yolo" "$(run "$P/js/verb.mjs" yolo | grep -o '"ok":true')" '"ok":true'
check "allowlist: node:child_process refused in ask" "$(run "$P/js/spawn.mjs" ask | grep -o 'refused by the fx permission gate')" 'refused by the fx permission gate'
check "red: node:child_process loads in yolo" "$(run "$P/js/spawn.mjs" yolo)" 'child_process loaded function'
check "routing: node:fs refused in ask, so writes go through fxHost verbs" "$(run "$P/js/fs.mjs" ask | grep -o 'refused by the fx permission gate')" 'refused by the fx permission gate'
check "red: node:fs writes in yolo" "$(run "$P/js/fs.mjs" yolo)" 'fs wrote'
echo "SAFE_MODE not tested: it runs edgejs under Wasmer, and this native quickjs build has EDGE_QUICKJS_WEBASSEMBLY off"
echo "EDGE_DONE $fails"
