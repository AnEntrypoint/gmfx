---- MODULE CredentialsTrace ----











EXTENDS Credentials, TraceObs, Sequences

VARIABLES i, bad, cmd, srv

Viol ==
    (IF NoV1LoginTaken THEN {} ELSE {"NoV1LoginTaken"}) \cup
    (IF UnreadableNeverOverwritten THEN {} ELSE {"UnreadableNeverOverwritten"}) \cup
    (IF SignedInKept THEN {} ELSE {"SignedInKept"}) \cup
    (IF LogoutStays THEN {} ELSE {"LogoutStays"})

Observed(d) ==
    /\ kind = d.kind
    /\ entries = d.entries
    /\ v1 = d.v1

Step(rec) ==
    CASE rec.event = "run" /\ rec.data.cmd = "unreadable" -> Unreadable /\ UNCHANGED <<cmd, srv>>
      [] rec.event = "run" /\ rec.data.cmd = "repair" -> Repair /\ UNCHANGED <<cmd, srv>>
      [] rec.event = "run" /\ rec.data.cmd = "delete" -> Delete /\ UNCHANGED <<cmd, srv>>
      [] rec.event = "run" -> UNCHANGED vars /\ cmd' = rec.data.cmd /\ srv' = rec.data.server
      [] rec.event = "observe" -> Observed(rec.data) /\ UNCHANGED vars /\ cmd' = "" /\ srv' = ""
      [] OTHER -> FALSE


Hidden ==
    /\ cmd # ""
    /\ \/ Get
       \/ (cmd = "logout" /\ Remove(srv))
       \/ (cmd = "put" /\ Put(srv))
    /\ UNCHANGED <<cmd, srv>>

TraceInit == Init /\ i = 0 /\ bad = Viol /\ cmd = "" /\ srv = ""

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
