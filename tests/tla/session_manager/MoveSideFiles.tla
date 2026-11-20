--------------------------- MODULE MoveSideFiles ---------------------------















EXTENDS Naturals, FiniteSets

CONSTANTS Handles

VARIABLES
    side,
    folder,
    blobs,
    mapped,
    terminal,
    open

vars == <<side, folder, blobs, mapped, terminal, open>>

TypeOK ==
    /\ side \subseteq Handles
    /\ folder \in {"present", "removed"}
    /\ blobs \subseteq Handles
    /\ mapped \in BOOLEAN
    /\ terminal \in {"side", "moved"}
    /\ open \in BOOLEAN

Init ==
    /\ side = Handles
    /\ folder = "present"
    /\ blobs = {}
    /\ mapped = FALSE
    /\ terminal = "side"
    /\ open = FALSE


Open ==
    /\ ~open
    /\ open' = TRUE
    /\ UNCHANGED <<side, folder, blobs, mapped, terminal>>


PutBlob(h) ==
    /\ open
    /\ ~mapped
    /\ h \in side
    /\ blobs' = blobs \cup {h}
    /\ UNCHANGED <<side, folder, mapped, terminal, open>>


WriteMap ==
    /\ open
    /\ ~mapped
    /\ blobs = Handles
    /\ mapped' = TRUE
    /\ UNCHANGED <<side, folder, blobs, terminal, open>>


MoveTerminal ==
    /\ open
    /\ mapped
    /\ terminal = "side"
    /\ terminal' = "moved"
    /\ UNCHANGED <<side, folder, blobs, mapped, open>>


RemoveSide ==
    /\ open
    /\ mapped
    /\ terminal = "moved"
    /\ folder = "present"
    /\ folder' = "removed"
    /\ side' = {}
    /\ UNCHANGED <<blobs, mapped, terminal, open>>


Stop ==
    /\ open
    /\ open' = FALSE
    /\ UNCHANGED <<side, folder, blobs, mapped, terminal>>

Done == folder = "removed"

Next ==
    \/ Open
    \/ \E h \in Handles : PutBlob(h)
    \/ WriteMap
    \/ MoveTerminal
    \/ RemoveSide
    \/ Stop

Spec == Init /\ [][Next]_vars



FairSpec == Spec /\ WF_vars(Open) /\ SF_vars(WriteMap) /\ SF_vars(MoveTerminal)
    /\ SF_vars(RemoveSide) /\ \A h \in Handles : SF_vars(PutBlob(h))

-----------------------------------------------------------------------------




Resolvable ==
    \A h \in Handles : (mapped /\ h \in blobs) \/ (~mapped /\ h \in side)


TerminalKept == folder = "removed" => terminal = "moved"


MapComplete == mapped => blobs = Handles


EventuallyDone == <>[]Done
=============================================================================
