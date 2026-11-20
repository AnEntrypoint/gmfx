---- MODULE RefreshLeaseTrace ----
























EXTENDS Integers, Sequences, FiniteSets, TraceObs

CONSTANTS RefreshMax, Budget, Slack, Tolerance

VARIABLES
    i, bad,
    owner,
    frozen,
    foreign,
    lastStamp

None == "none"
Max(a, b) == IF a > b THEN a ELSE b

TraceInit == i = 0 /\ bad = {} /\ owner = None /\ frozen = {} /\ foreign = FALSE /\ lastStamp = -1


From(started) == IF lastStamp > started THEN lastStamp ELSE started
GoAheadAt(started) == Max(From(started) + RefreshMax, started + Budget + Slack) + Slack

Broken(r) ==
    LET d == r.data IN
    (IF r.event \in {"take", "foreign"} /\ owner # None THEN {"OneOwner"} ELSE {}) \cup
    (IF r.event = "stamp" /\ owner # d.p THEN {"OneOwner"} ELSE {}) \cup
    (IF r.event = "goahead" /\ owner # None /\ ~(owner \in frozen \/ foreign)
        THEN {"NoGoAheadPastLiveRefresher"} ELSE {}) \cup
    (IF r.event = "goahead" /\
        (d.at + Tolerance < GoAheadAt(d.started) \/ d.at > GoAheadAt(d.started) + Tolerance)
        THEN {"GoAheadOnTime"} ELSE {})

Step(r) ==
    LET d == r.data IN
    CASE r.event \in {"take", "stamp"} ->
            owner' = d.p /\ lastStamp' = d.at /\ UNCHANGED <<frozen, foreign>>
      [] r.event = "foreign" ->
            owner' = d.p /\ foreign' = TRUE /\ UNCHANGED <<frozen, lastStamp>>
      [] r.event \in {"release", "kill", "foreign_release"} ->
            (owner' = (IF owner = d.p THEN None ELSE owner))
            /\ (foreign' = (IF owner = d.p THEN FALSE ELSE foreign))
            /\ frozen' = frozen \ {d.p}
            /\ UNCHANGED lastStamp
      [] r.event = "freeze" -> frozen' = frozen \cup {d.p} /\ UNCHANGED <<owner, foreign, lastStamp>>
      [] r.event = "thaw" -> frozen' = frozen \ {d.p} /\ UNCHANGED <<owner, foreign, lastStamp>>
      [] r.event = "goahead" -> UNCHANGED <<owner, frozen, foreign, lastStamp>>
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
