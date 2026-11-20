---------------------------- MODULE RefreshWitness ----------------------------


EXTENDS Refresh
Before(a, b) == \E i, j \in 1..Len(history) : i < j /\ history[i] \in a /\ history[j] = b
NoReuse == ~Before({"Begin"}, "Reuse")
NoReuseAfterEdit == ~Before({"Edit:a.txt", "Edit:b.txt"}, "Reuse")


NoReuseAfterIgnore == ~\E i, k, m, j \in 1..Len(history) :
    /\ i < k /\ k < m /\ m < j
    /\ history[i] = "Edit:b.txt" /\ history[k] = "ChangeIgnore"
    /\ history[m] = "Tick" /\ history[j] = "Reuse"

NoEditAfterReuse == ~\E i, j \in 1..Len(history) :
    i < j /\ history[i] = "Reuse" /\ history[j] \in {"Edit:a.txt", "Edit:b.txt"}
NoIgnoreChangeAfterReuse == ~\E i, k, j \in 1..Len(history) :
    /\ i < k /\ k < j
    /\ history[i] = "Edit:b.txt" /\ history[k] = "Reuse"
    /\ history[j] = "ChangeIgnore"
=============================================================================
