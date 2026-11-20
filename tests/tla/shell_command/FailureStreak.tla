---------------------------- MODULE FailureStreak ----------------------------
























EXTENDS Naturals, Sequences

CONSTANTS
  Cmds,
  Limit,
  GuardLimit,
  Resets,
  MaxSteps

Writes == {"none", "ok", "failed"}

VARIABLES
  streak,
  hist,
  ended

vars == <<streak, hist, ended>>

TypeOK ==
  /\ streak \in [Cmds -> Nat]
  /\ hist \in Seq([fail : SUBSET Cmds, write : Writes])
  /\ ended \in BOOLEAN

RestartsStreak(w) ==
  CASE Resets = "ok" -> w = "ok"
    [] Resets = "any" -> w # "none"
    [] OTHER -> FALSE

Init ==
  /\ streak = [c \in Cmds |-> 0]
  /\ hist = << >>
  /\ ended = FALSE




Step(fail, write) ==
  /\ ~ended
  /\ Len(hist) < MaxSteps
  /\ streak' = [c \in Cmds |->
       IF c \notin fail THEN 0
       ELSE IF RestartsStreak(write) THEN 1
       ELSE streak[c] + 1]
  /\ ended' = \E c \in fail : streak'[c] >= GuardLimit
  /\ hist' = Append(hist, [fail |-> fail, write |-> write])

Next == \E fail \in SUBSET Cmds, write \in Writes : Step(fail, write)

Spec == Init /\ [][Next]_vars

----------------------------------------------------------------------------




Run(c, i, k) ==
  /\ k <= i
  /\ \A j \in (i - k + 1)..i : c \in hist[j].fail
  /\ \A j \in (i - k + 2)..i : hist[j].write # "ok"

EditedRetryContinues ==
  ended => hist[Len(hist)].write # "ok"

StopsOnlyAfterLimit ==
  ended => \E c \in Cmds : Run(c, Len(hist), Limit)

BlindLoopBounded ==
  \A i \in 1..Len(hist), c \in Cmds :
    Run(c, i, Limit) => (ended /\ i = Len(hist))
=============================================================================
