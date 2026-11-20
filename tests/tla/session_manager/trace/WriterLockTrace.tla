-------------------------- MODULE WriterLockTrace --------------------------
















EXTENDS WriterLock, TraceData, TLC

VARIABLE l
tvars == <<vars, l>>

TraceProcs == {"p1", "p2"}
TraceThreads == {"t1", "t2"}
TraceMaxLines == 64
TraceNone == "none"

ASSUME TLCSet(1, 0)

Matches(e) ==
    /\ holder' = e.holder
    /\ alive' = e.alive
    /\ opened' = e.opened
    /\ nextSeq' = e.nextSeq
    /\ mutex' = e.mutex
    /\ file' = e.file

Act(e) ==
    CASE e.event = "Open"            -> Open(e.p)
      [] e.event = "Close"           -> Close(e.p)
      [] e.event = "Crash"           -> Crash(e.p)
      [] e.event = "Restart"         -> Restart(e.p)
      [] e.event = "Acquire"         -> Acquire(e.p, e.t)
      [] e.event = "WriteAndRelease" -> WriteAndRelease(e.p, e.t)

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
