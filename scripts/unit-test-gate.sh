#!/bin/bash
set -u
export PATH=/config/tools/zig-0.17.0:$PATH
cd "$(dirname "$0")/.." || exit 2
LOG="${1:-/tmp/fx-gate.log}"
exec 9>/tmp/fx-build.lock
flock 9
zig build install-test > "$LOG.build" 2>&1
BUILD_RC=$?
if [ "$BUILD_RC" -ne 0 ]; then
  echo "BUILD_EXIT=$BUILD_RC"
  tail -40 "$LOG.build"
  exit "$BUILD_RC"
fi
timeout 1200 ./zig-out/bin/fx-test > "$LOG" 2>&1
TEST_RC=$?
echo "BUILD_EXIT=0"
echo "TEST_EXIT=$TEST_RC"
grep -E 'FAIL|panic|passed|failed|reached unreachable' "$LOG" | tail -60
exit "$TEST_RC"
