#!/bin/sh




















set -eu

cd "$(dirname "$0")"

. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
CacheWarming cache-warming -
CacheWarming cache-warming-deep -
CacheWarming cache-warming-mutation-ping-at-ttl NoWritingPing
CacheWarming cache-warming-mutation-no-cap PingsBounded
CacheWarming cache-warming-mutation-no-cap-action PingWithinCap
CacheWarming cache-warming-mutation-no-late-check NoWritingPing
CacheWarming cache-warming-mutation-stale-finish NoStaleStop
CacheWarming cache-warming-mutation-ping-while-sending NoPingWhileSending
CacheWarming cache-warming-mutation-no-shutdown-cancel NoPingAfterShutdown
VERDICTS
