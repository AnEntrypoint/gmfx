---- MODULE Credentials ----























EXTENDS Naturals, FiniteSets

CONSTANTS
    Names,
    Faults,
    InitKinds,
    InitEntries,
    InitV1

Kinds == {"absent", "ok", "unreadable"}

VARIABLES
    kind,
    entries,
    v1,
    loggedOut,
    kept,
    taken,
    overwritten

vars == <<kind, entries, v1, loggedOut, kept, taken, overwritten>>

TypeOK ==
    /\ kind \in Kinds
    /\ entries \subseteq Names
    /\ v1 \subseteq Names
    /\ loggedOut \subseteq Names
    /\ kept \subseteq Names
    /\ taken \in BOOLEAN /\ overwritten \in BOOLEAN

Init ==
    /\ kind \in InitKinds
    /\ entries \in (IF kind = "absent" THEN {{}} ELSE SUBSET InitEntries)
    /\ v1 \in SUBSET InitV1
    /\ loggedOut = {}
    /\ kept = entries
    /\ taken = FALSE /\ overwritten = FALSE


Unread == kind = "unreadable"
SavedEntries == IF kind = "ok" THEN entries ELSE {}


Write(e, fresh) ==
    /\ kind' = "ok"
    /\ entries' = e
    /\ taken' = (taken \/ ((e \ (SavedEntries \cup {fresh})) \cap v1) # {})
    /\ overwritten' = (overwritten \/ Unread)

Same == UNCHANGED <<kind, entries, taken, overwritten>>



Get ==
    /\ Same
    /\ UNCHANGED <<v1, loggedOut, kept>>



Put(n) ==
    /\ ~Unread
    /\ Write(SavedEntries \cup {n}, n)
    /\ loggedOut' = loggedOut \ {n}
    /\ kept' = kept \cup {n}
    /\ UNCHANGED v1



Remove(n) ==
    /\ ~Unread
    /\ IF n \in SavedEntries THEN Write(SavedEntries \ {n}, "") ELSE Same
    /\ loggedOut' = loggedOut \cup {n}
    /\ kept' = kept \ {n}
    /\ UNCHANGED v1



Unreadable ==
    /\ "unreadable" \in Faults /\ kind = "ok"
    /\ kind' = "unreadable"
    /\ UNCHANGED <<entries, v1, loggedOut, kept, taken, overwritten>>



Repair ==
    /\ "repair" \in Faults /\ kind = "unreadable"
    /\ kind' = "ok"
    /\ UNCHANGED <<entries, v1, loggedOut, kept, taken, overwritten>>


Delete ==
    /\ "delete" \in Faults /\ kind # "absent"
    /\ kind' = "absent" /\ entries' = {}
    /\ kept' = {}
    /\ UNCHANGED <<v1, loggedOut, taken, overwritten>>


V1Login(n) ==
    /\ "v1login" \in Faults /\ n \notin v1
    /\ v1' = v1 \cup {n}
    /\ UNCHANGED <<kind, entries, loggedOut, kept, taken, overwritten>>

Next ==
    \/ Get
    \/ \E n \in Names : Put(n) \/ Remove(n) \/ V1Login(n)
    \/ Unreadable
    \/ Repair
    \/ Delete

Spec == Init /\ [][Next]_vars




NoV1LoginTaken == ~taken


SignedInKept == kind = "ok" => kept \subseteq entries



LogoutStays == kind = "ok" => loggedOut \cap entries = {}


UnreadableNeverOverwritten == ~overwritten
====
