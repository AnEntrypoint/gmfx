----------------------------- MODULE MCListing -----------------------------





EXTENDS FuzzyMatch, FiniteSets

CONSTANTS Alphabet, MaxQuery, MaxField, NumItems

Strings(n) == UNION {[1..k -> Alphabet] : k \in 0..n}
Items == {<<[text |-> name, kind |-> "name"], [text |-> text, kind |-> "text"]>> :
            name \in Strings(MaxField), text \in Strings(MaxField)}

VARIABLES q, items
vars == <<q, items>>

Init == q \in Strings(MaxQuery) /\ items \in [1..NumItems -> Items]
Next == UNCHANGED vars
Spec == Init /\ [][Next]_vars

Rk(i) == TierRank[Match(q, items[i]).tier]
Fd(i) == Match(q, items[i]).field
MatchSet == {i \in 1..NumItems : Rk(i) > 0}
Ranked == Listing(items, q, "ranked")
Filtered == Listing(items, q, "filtered")
Shows(l) == {l[k] : k \in 1..Len(l)}

TypeOK == Ranked \in Seq(1..NumItems) /\ Filtered \in Seq(1..NumItems)



ListingSortedStable ==
    /\ Shows(Ranked) = MatchSet
    /\ Len(Ranked) = Cardinality(MatchSet)
    /\ \A a, b \in 1..Len(Ranked) :
         a < b =>
           \/ Rk(Ranked[a]) > Rk(Ranked[b])
           \/ /\ Rk(Ranked[a]) = Rk(Ranked[b])
              /\ \/ Fd(Ranked[a]) < Fd(Ranked[b])
                 \/ Fd(Ranked[a]) = Fd(Ranked[b]) /\ Ranked[a] < Ranked[b]



LegacyRowsFirst ==
    \A a, b \in 1..Len(Ranked) :
        (a < b /\ Rk(Ranked[b]) >= TierRank["substring"]) => Rk(Ranked[a]) >= TierRank["substring"]

AsTypedSet == {i \in MatchSet : Rk(i) >= TierRank["substring"]}


FilteredKeepsOrder ==
    /\ Shows(Filtered) \subseteq MatchSet
    /\ \A a, b \in 1..Len(Filtered) : a < b => Filtered[a] < Filtered[b]



FilteredPrefersAsTyped ==
    Shows(Filtered) = (IF AsTypedSet # {} THEN AsTypedSet ELSE MatchSet)

=============================================================================
