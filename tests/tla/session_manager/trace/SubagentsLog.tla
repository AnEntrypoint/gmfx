--------------------------- MODULE SubagentsLog ---------------------------












EXTENDS Subagents, SavedChildren, TLC

ASSUME TLCSet(1, 0)

LogNext ==
    /\ Next
    /\ Len(plog') <= Len(Target)
    /\ plog' = SubSeq(Target, 1, Len(plog'))

LogSpec == Init /\ [][LogNext]_vars

Progress ==
    IF Len(plog) > TLCGet(1)
    THEN TLCSet(1, Len(plog)) /\ PrintT(<<"matched_lines", Len(plog)>>)
    ELSE TRUE

NotWritten == ~(plog = Target /\ childLog = FinalChildLog)
=============================================================================
