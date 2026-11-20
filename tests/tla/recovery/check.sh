#!/bin/sh











































set -eu

cd "$(dirname "$0")"

. ../lib/tlc.sh

tlc_verdicts "$@" <<'EOF'
Recovery recovery -
Recovery recovery-deep -
Recovery recovery-mutation-stall-stop NeverGivesUp
Recovery recovery-mutation-no-wake temporal
Recovery recovery-mutation-stale-socket NoFalseAlarm
Recovery recovery-mutation-frozen-status StatusHonest
Recovery recovery-mutation-no-closing ResumesAfterClose
Recovery recovery-mutation-never-ask CrashLoopAsks
Recovery recovery-mutation-hot-retry NoHotRetry
Recovery recovery-mutation-send-without-save SaveBeforeSend
RecoveryTimed recovery-timed -
RecoveryTimed recovery-mutation-unbounded-wait WaitBounded
RecoveryTimed recovery-mutation-frozen-countdown StatusFresh
RecoveryTimed recovery-mutation-no-handoff HandsOff
Resume resume -
Resume resume-deep -
Resume resume-today AutoResumes
Resume resume-mutation-no-closing NoFalseCrashQuestion
Resume resume-mutation-no-clear NoFalseCrashQuestion
Resume resume-mutation-send-before-save CrashLoopAsks
Resume resume-mutation-reset-on-resume CrashLoopAsks
Resume resume-mutation-resume-answered DoneNeverResent
Resume resume-mutation-resume-cancelled CancelNeverResumes
Resume resume-mutation-ignore-age OldAsks
Resume resume-mutation-no-lock OneWorker
EOF
