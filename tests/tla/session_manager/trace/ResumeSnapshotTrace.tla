------------------------ MODULE ResumeSnapshotTrace ------------------------














EXTENDS ResumeSnapshot, TraceData, TLC

VARIABLE l
tvars == <<vars, l>>

TraceVals == {"v1", "v2"}
TraceMaxLen == 64
TraceNoVal == "none"

ASSUME TLCSet(1, 0)

Matches(e) == log' = e.log

Act(e) ==
    CASE e.event = "Set"      -> Set(e.v)
      [] e.event = "Start"    -> Start
      [] e.event = "Commit"   -> Commit
      [] e.event = "Snapshot" -> Snapshot

TraceInit == Init /\ l = 1

TraceNext ==
    /\ l <= Len(Trace)
    /\ Act(Trace[l])
    /\ Matches(Trace[l])
    /\ l' = l + 1

TraceSpec == TraceInit /\ [][TraceNext]_tvars

Progress ==
    IF l - 1 > TLCGet(1)
    THEN TLCSet(1, l - 1) /\ PrintT(<<"matched_lines", l - 1>>)
    ELSE TRUE

TraceIncomplete == l <= Len(Trace)
=============================================================================
