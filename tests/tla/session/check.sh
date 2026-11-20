#!/bin/sh
























set -eu

cd "$(dirname "$0")"

. ../lib/tlc.sh

sim="-simulate num=${SIM_RUNS:-20000} -depth 40 -seed 1"
tlc_verdicts "$@" <<EOF
ShellSession holds -
ShellSession witness-saved-empty-status NoSavedEmptyStatus
ShellSession witness-unsaved-status NoUnsavedStatus
ShellSession witness-storeless-status NoStorelessStatus
ShellSession witness-empty-exit-line NoEmptyExitLine
ShellSession witness-resume-after-crash NoResumeAfterCrash
ShellSession mutant-saved-by-turns StatusUnsavedIsAbsent
ShellSession mutant-saved-on-open StatusSavedIsOnDisk
ShellSession mutant-exit-by-turns ExitAgreesWithStatus
ShellSession mutant-status-launch-id StatusNamesOpenSession
ShellSession mutant-keep-pristine DiscardedNeverSaved
ShellSession mutant-reuse-id NewIdsAreFresh
ShellSession mutant-fork-held ForkOnDisk
ShellSession mutant-drop-on-switch SavedStaysSaved
ShellSession simulate simulate $sim
TurnStream stream-holds -
TurnStream stream-before-safe -
TurnStream stream-before-reparses NoReparseOfStamped
TurnStream stream-mutant-lose-on-recover StampIsBirth
TurnStream stream-mutant-share-stamp StampIsOwn
TurnStream stream-mutant-bytes-only SupersedeExplained
TurnStream stream-mutant-loose-compare CommitIsFinal
TurnStream stream-mutant-mix CommitIsFinal
TurnStream stream-mutant-prefix-only CommitIsFinal
TurnStream stream-witness-supersede NeverSuperseded
TurnStream stream-witness-commit NeverCommittedWhole
TurnStream stream-witness-compaction NeverCommittedAfterCut
TurnStream stream-witness-recovery NeverCommittedAfterRecovery
TurnStream stream-witness-missed-path MissedPathsNeverParse
TurnStream stream-simulate simulate $sim
TurnStream stream-simulate-before simulate $sim
EOF
