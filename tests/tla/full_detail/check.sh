#!/bin/sh









set -eu
cd "$(dirname "$0")"
. ../lib/tlc.sh
tlc_find
tlc_verdicts "$@" <<'CHECKS'
FullDetailOrder FullDetailOrder -
FullDetailOrder PinTop PromptFirst
FullDetailOrder NeverSaved ReplayMatchesSaved
FullDetailOrder SavedAtCommit ReplayMatchesSaved
FullDetailOrder NoFailureSplit ReplayMatchesSaved
FullDetailLog FullDetailLog -
FullDetailLog RecordsAfterSteering AppendOnly
CHECKS
