-------------------------- MODULE LeanUsageDrive --------------------------











EXTENDS LeanUsage

TimerDue(p) ==
    /\ open[p]
    /\ FloorClear(p)
    /\ lastStart[p] # None
    /\ Since(lastStart[p], TIMER)

DriveNext ==
    IF \E p \in Procs : TimerDue(p)
    THEN \E p \in Procs : Timer(p)
    ELSE \/ Tick
         \/ \E p \in Procs :
               Open(p) \/ Close(p) \/ Manual(p) \/ Complete(p) \/ Fail(p)

DriveSpec == Init /\ [][DriveNext]_vars
=============================================================================
