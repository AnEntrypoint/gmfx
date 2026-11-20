------------------------- MODULE TurnLifecycleLog -------------------------












EXTENDS TurnLifecycle, SavedLog, TLC

ASSUME TLCSet(1, 0)

LogNext == Next /\ Prefix(log', Target)

LogSpec == Init /\ [][LogNext]_vars


Progress ==
    IF Len(log) > TLCGet(1)
    THEN TLCSet(1, Len(log)) /\ PrintT(<<"matched_lines", Len(log)>>)
    ELSE TRUE

NotWritten == log # Target
=============================================================================
