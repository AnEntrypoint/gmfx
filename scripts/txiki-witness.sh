#!/bin/sh
set -u
fx_bin=${1:-zig-out/bin/fx}
case $fx_bin in /*) ;; *) fx_bin=$(pwd)/$fx_bin ;; esac
work=$(mktemp -d)
failures=0
child_pids=""

cleanup() {
    for pid in $child_pids; do
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
    done
    rm -rf "$work"
}
trap cleanup EXIT

verdict() {
    if [ "$1" = pass ]; then
        printf 'PASS %s\n' "$2"
    else
        printf 'FAIL %s\n' "$2"
        failures=$((failures + 1))
    fi
}

run_js() {
    out_file=$1
    shift
    (cd "$work" && timeout 30 "$fx_bin" js "$@" >"$out_file" 2>"$out_file.err") &
    run_pid=$!
    child_pids="$child_pids $run_pid"
    wait "$run_pid"
    run_status=$?
}

expect_in() {
    grep -q -- "$1" "$2"
}

[ -x "$fx_bin" ] || { printf 'FAIL no executable at %s\n' "$fx_bin"; exit 2; }

printf "export const word = 'alpha';\n" >"$work/dep.mjs"
printf "import { word } from './dep.mjs';\nreturn word + '-imported';\n" >"$work/main.mjs"
cp "$work/dep.mjs" "$work/dep.mjs.orig"

run_js "$work/module.out" main.mjs
if [ "$run_status" -eq 0 ] && expect_in 'alpha-imported' "$work/module.out"; then
    verdict pass "module on disk imports another module"
else
    verdict fail "module on disk imports another module"
fi

printf "export const word = 'beta';\n" >"$work/dep.mjs"
run_js "$work/module.mut.out" main.mjs
if expect_in 'beta-imported' "$work/module.mut.out" && ! expect_in 'alpha-imported' "$work/module.mut.out"; then
    verdict pass "red check: a changed dependency changes the output"
else
    verdict fail "red check: a changed dependency changes the output"
fi
cp "$work/dep.mjs.orig" "$work/dep.mjs"
if cmp -s "$work/dep.mjs.orig" "$work/dep.mjs"; then
    verdict pass "dependency restored byte for byte"
else
    verdict fail "dependency restored byte for byte"
fi

printf 'while (true) {}\n' >"$work/spin.cjs"
cp "$work/spin.cjs" "$work/spin.cjs.orig"
run_js "$work/spin.out" spin.cjs --deadline-ms 500
if [ "$run_status" -eq 1 ] && expect_in 'passed its JavaScript deadline of 500 ms' "$work/spin.out"; then
    verdict pass "while(true){} body stopped at the deadline with the named error"
else
    verdict fail "while(true){} body stopped at the deadline with the named error (status $run_status)"
fi

printf 'return 7;\n' >"$work/spin.cjs"
run_js "$work/spin.mut.out" spin.cjs --deadline-ms 500
if [ "$run_status" -eq 0 ] && ! expect_in 'passed its JavaScript deadline' "$work/spin.mut.out"; then
    verdict pass "red check: a terminating body does not raise the deadline error"
else
    verdict fail "red check: a terminating body does not raise the deadline error"
fi
cp "$work/spin.cjs.orig" "$work/spin.cjs"
if cmp -s "$work/spin.cjs.orig" "$work/spin.cjs"; then
    verdict pass "spin body restored byte for byte"
else
    verdict fail "spin body restored byte for byte"
fi

printf "return gm.fs_write({ path: 'gate-target.txt', base64: 'd3JpdHRlbg==' });\n" >"$work/gate.cjs"
cp "$work/gate.cjs" "$work/gate.cjs.orig"
rm -f "$work/gate-target.txt"
run_js "$work/gate.out" gate.cjs
if [ ! -e "$work/gate-target.txt" ] && expect_in '"value":{"ok":false,"code":"EFX_PERMISSION_DENIED"' "$work/gate.out"; then
    verdict pass "fs_write host verb refused by the Zig gate in ask mode"
else
    verdict fail "fs_write host verb refused by the Zig gate in ask mode"
fi

run_js "$work/gate.mut.out" gate.cjs --permission-mode yolo
if [ -e "$work/gate-target.txt" ] && expect_in '"value":{"ok":true,"written":7' "$work/gate.mut.out"; then
    verdict pass "red check: the same verb is admitted in yolo mode"
else
    verdict fail "red check: the same verb is admitted in yolo mode"
fi
rm -f "$work/gate-target.txt"
cp "$work/gate.cjs.orig" "$work/gate.cjs"
if cmp -s "$work/gate.cjs.orig" "$work/gate.cjs"; then
    verdict pass "gate body restored byte for byte"
else
    verdict fail "gate body restored byte for byte"
fi

cat >"$work/alias.mjs" <<'EOF'
import fs from 'node:fs';
import { join } from 'path';
fs.writeFileSync('alias-note.txt', 'node-alias');
return join('alias', fs.readFileSync('alias-note.txt', 'utf8'));
EOF
run_js "$work/alias.out" alias.mjs --permission-mode yolo
if [ "$run_status" -eq 0 ] && expect_in '"value":"alias/node-alias"' "$work/alias.out"; then
    verdict pass "node:fs and bare path resolve through the fx:host alias table"
else
    verdict fail "node:fs and bare path resolve through the fx:host alias table (status $run_status)"
fi

sed "s#'node:fs'#'node:inspector'#" "$work/alias.mjs" >"$work/alias-gap.mjs"
run_js "$work/alias-gap.out" alias-gap.mjs --permission-mode yolo
if [ "$run_status" -eq 1 ] && expect_in "'node:inspector' is not provided by fx:host yet" "$work/alias-gap.out"; then
    verdict pass "red check: a name off the alias table fails with the named gap error"
else
    verdict fail "red check: a name off the alias table fails with the named gap error (status $run_status)"
fi

if [ "$failures" -eq 0 ]; then
    printf 'txiki witness: all checks passed\n'
    exit 0
fi
printf 'txiki witness: %s checks failed\n' "$failures"
exit 1
