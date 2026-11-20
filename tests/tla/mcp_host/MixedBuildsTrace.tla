---- MODULE MixedBuildsTrace ----













EXTENDS MixedBuilds, TraceObs, Sequences

VARIABLES i, bad, cmd

Viol ==
    (IF NoLoginErasedByOlder THEN {} ELSE {"NoLoginErasedByOlder"}) \cup
    (IF NoLoginEndedByOlder THEN {} ELSE {"NoLoginEndedByOlder"}) \cup
    (IF OlderLoginNotTaken THEN {} ELSE {"OlderLoginNotTaken"})

Observed(d) ==
    /\ v2kind = d.v2kind
    /\ (v2 # None) = d.v2
    /\ (v3 # None) = d.v3

Step(rec) ==
    CASE rec.event = "older" /\ rec.data.op = "save" -> OlderRefresh /\ older' # None /\ UNCHANGED cmd
      [] rec.event = "older" /\ rec.data.op = "remove" -> OlderEnds /\ UNCHANGED cmd
      [] rec.event = "run" -> UNCHANGED vars /\ cmd' = rec.data.cmd
      [] rec.event = "observe" -> Observed(rec.data) /\ UNCHANGED vars /\ cmd' = ""
      [] OTHER -> FALSE



Hidden ==
    /\ cmd # ""
    /\ \/ ThisGet
       \/ (cmd = "signin" /\ ThisSignIn)
       \/ (cmd = "logout" /\ ThisLogout)
    /\ UNCHANGED cmd

TraceInit == Init /\ i = 0 /\ bad = Viol /\ cmd = ""

TraceNext ==
    \/ /\ i < Len(ObsTrace)
       /\ Step(ObsTrace[i + 1])
       /\ i' = i + 1
       /\ bad' = bad \cup Viol'
    \/ /\ Hidden
       /\ UNCHANGED i
       /\ bad' = bad \cup Viol'

NotDone == i < Len(ObsTrace)
NotDoneClean == i < Len(ObsTrace) \/ bad # {}
NotDoneDirty == i < Len(ObsTrace) \/ bad = {}
====
