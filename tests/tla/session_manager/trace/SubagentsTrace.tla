--------------------------- MODULE SubagentsTrace ---------------------------













EXTENDS Subagents, TraceData, TLC

VARIABLE l
tvars == <<vars, l>>

TraceChildren == {"c1", "c2"}
TraceMaxWork == 2

ASSUME TLCSet(1, 0)

Matches(e) ==
    /\ plog' = e.plog
    /\ childLog' = e.childLog
    /\ thread' = e.thread
    /\ up' = e.up
    /\ repairing' = e.repairing

Act(e) ==
    CASE e.event = "Spawn"          -> Spawn(e.c)
      [] e.event = "ChildStart"     -> ChildStart(e.c)
      [] e.event = "ChildFinish"    -> ChildFinish(e.c)
      [] e.event = "Cancel"         -> Cancel(e.c)
      [] e.event = "RepairChild"    -> RepairChild(e.c)
      [] e.event = "Crash"          -> Crash
      [] e.event = "Reopen"         -> Reopen
      [] e.event = "RepairDone"     -> RepairDone

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
