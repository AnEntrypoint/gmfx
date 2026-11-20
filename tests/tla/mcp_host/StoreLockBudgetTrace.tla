---- MODULE StoreLockBudgetTrace ----




























EXTENDS Integers, Sequences, FiniteSets, TraceObs

CONSTANTS Budget, Slack, Tolerance

VARIABLES
    i, bad,
    owner,
    stampAt,
    frozen,
    excused,
    foreign,
    lastStamp

None == "none"
Max(a, b) == IF a > b THEN a ELSE b

TraceInit ==
    /\ i = 0 /\ bad = {} /\ owner = None /\ stampAt = 0
    /\ frozen = {} /\ excused = {} /\ foreign = FALSE /\ lastStamp = -1


Broken(r) ==
    LET d == r.data IN
    (IF r.event \in {"take", "foreign"} /\ owner # None THEN {"OneOwner"} ELSE {}) \cup
    (IF r.event \in {"stamp", "release"} /\ owner = d.p /\ ~(d.p \in excused) /\ d.at > stampAt + Budget + Tolerance
        THEN {"HoldWithinBudget"} ELSE {}) \cup
    (IF r.event = "stamp" /\ owner # d.p THEN {"OneOwner"} ELSE {}) \cup
    (IF r.event = "giveup" /\ ~(owner # None /\ (owner \in frozen \/ foreign))
        THEN {"NoGiveUpOnLiveHolder"} ELSE {}) \cup
    (IF r.event = "giveup" /\
        (d.at + Tolerance < Max(lastStamp, d.started) + Budget + Slack \/
         d.at > Max(lastStamp, d.started) + Budget + Slack + Tolerance)
        THEN {"GiveUpOnTime"} ELSE {})

Step(r) ==
    LET d == r.data IN
    CASE r.event = "take" ->
            owner' = d.p /\ stampAt' = d.at /\ lastStamp' = d.at /\ foreign' = FALSE /\ UNCHANGED <<frozen, excused>>
      [] r.event = "stamp" ->
            stampAt' = d.at /\ lastStamp' = d.at /\ UNCHANGED <<owner, frozen, excused, foreign>>
      [] r.event = "foreign" ->
            owner' = d.p /\ foreign' = TRUE /\ UNCHANGED <<stampAt, lastStamp, frozen, excused>>
      [] r.event \in {"release", "kill", "foreign_release"} ->
            (owner' = (IF owner = d.p THEN None ELSE owner))
            /\ (foreign' = (IF owner = d.p THEN FALSE ELSE foreign))
            /\ frozen' = frozen \ {d.p}
            /\ excused' = excused \ {d.p}
            /\ UNCHANGED <<stampAt, lastStamp>>
      [] r.event = "freeze" ->
            frozen' = frozen \cup {d.p} /\ excused' = excused \cup {d.p} /\ UNCHANGED <<owner, stampAt, foreign, lastStamp>>
      [] r.event = "thaw" -> frozen' = frozen \ {d.p} /\ UNCHANGED <<owner, stampAt, foreign, lastStamp, excused>>
      [] r.event = "giveup" -> UNCHANGED <<owner, stampAt, frozen, excused, foreign, lastStamp>>
      [] r.event = "scribble" -> lastStamp' = -1 /\ UNCHANGED <<owner, stampAt, frozen, excused, foreign>>
      [] OTHER -> FALSE

TraceNext ==
    /\ i < Len(ObsTrace)
    /\ Step(ObsTrace[i + 1])
    /\ bad' = bad \cup Broken(ObsTrace[i + 1])
    /\ i' = i + 1

NotDone == i < Len(ObsTrace)
NotDoneClean == i < Len(ObsTrace) \/ bad # {}
NotDoneDirty == i < Len(ObsTrace) \/ bad = {}
====
