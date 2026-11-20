------------------------ MODULE TurnLifecycleTrace ------------------------











EXTENDS TurnLifecycle, TraceData, TLC

VARIABLE l
tvars == <<vars, l>>




TraceMaxLen == 4096

ASSUME TLCSet(1, 0)

Matches(e) ==
    /\ log' = e.log
    /\ status' = e.status
    /\ fresh' = e.fresh

Act(e) ==
    CASE e.event = "Create" -> Create
      [] e.event = "Write"  -> Write(e.kind)
      [] e.event = "Close"  -> Close
      [] e.event = "Crash"  -> Crash
      [] e.event = "Reopen" -> Reopen

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
