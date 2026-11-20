------------------------------ MODULE ForkLog ------------------------------












EXTENDS Naturals, Sequences, FiniteSets, TLC, SavedFork

VARIABLE checked

Starts(s) == {i \in 1..Len(s) : s[i].k = "start"}
Ends(s) == {i \in 1..Len(s) : s[i].k \in {"commit", "interrupt"}}

IsPrefix ==
    /\ Len(Copied) <= Len(Source)
    /\ \A i \in 1..Len(Copied) : Copied[i] = Source[i]

AtBoundary == Cardinality(Starts(Copied)) = Cardinality(Ends(Copied))

LogInit == checked = FALSE
LogNext == ~checked /\ IsPrefix /\ AtBoundary /\ PrintT(<<"matched_lines", Len(Copied)>>) /\ checked' = TRUE
LogSpec == LogInit /\ [][LogNext]_checked

NotWritten == ~checked
=============================================================================
