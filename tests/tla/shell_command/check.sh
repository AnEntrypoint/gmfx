#!/bin/sh

























set -eu

cd "$(dirname "$0")"

. ../lib/tlc.sh

tlc_verdicts "$@" <<'EOF'
GitAdmission git-admission - -deadlock
GitAdmission git-admission-mutation HoldSafety -deadlock
ShellContract proposed -
ShellContract current-holds -
ShellContract current-completeness Completeness
ShellContract current-history HistoryFidelity
ShellContract current-zsh ZshForgiving
ShellContract mutant-admission-raw AdmissionConsistency
ShellContract mutant-guess Exactness
FailureStreak failure-streak - -deadlock
FailureStreak failure-streak-current EditedRetryContinues -deadlock
FailureStreak failure-streak-mutant-any-write BlindLoopBounded -deadlock
FailureStreak failure-streak-mutant-late BlindLoopBounded -deadlock
FailureStreak failure-streak-mutant-early StopsOnlyAfterLimit -deadlock
EOF
