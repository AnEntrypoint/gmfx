------------------------- MODULE SessionLogTrace -------------------------



















EXTENDS SessionLog, TraceData, TLC

VARIABLE l
tvars == <<vars, l>>

ASSUME TLCSet(1, 0)



Matches(e) ==
    /\ Len(log') = e.log_len
    /\ IF Len(log') = 0 THEN e.tail_done ELSE log'[Len(log')].done = e.tail_done
    /\ Len(e.seqs) <= Len(log')
    /\ \A i \in 1..Len(e.seqs) : log'[i].seq = e.seqs[i]
    /\ durable' = e.durable
    /\ acked' = e.acked
    /\ status' = e.status

Act(e) ==
    CASE e.event = "BeginWrite"   -> BeginWrite
      [] e.event = "FinishWrite"  -> FinishWrite
      [] e.event = "Fsync"        -> Fsync
      [] e.event = "ProcessCrash" -> ProcessCrash
      [] e.event = "PowerLoss"    -> PowerLoss
      [] e.event = "Recover"      -> Recover

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
