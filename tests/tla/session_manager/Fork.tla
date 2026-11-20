------------------------------- MODULE Fork -------------------------------













EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS Ids, Blobs, MaxLen, NoBlob

VARIABLES
    st,
    lg,
    links,
    base,
    lost

vars == <<st, lg, links, base, lost>>

E(k, b) == [k |-> k, b |-> b]

Count(l, k) == Cardinality({i \in 1..Len(l) : l[i].k = k})
IsOpen(l) == Count(l, "start") > Count(l, "commit")

TypeOK ==
    /\ st \in [Ids -> {"none", "live", "deleted"}]
    /\ links \in [Ids -> SUBSET Blobs]
    /\ lost \in [Ids -> SUBSET Blobs]

Init ==
    /\ st = [s \in Ids |-> "none"]
    /\ lg = [s \in Ids |-> <<>>]
    /\ links = [s \in Ids |-> {}]
    /\ base = [s \in Ids |-> <<>>]
    /\ lost = [s \in Ids |-> {}]

Create(s) ==
    /\ st[s] = "none"
    /\ st' = [st EXCEPT ![s] = "live"]
    /\ lg' = [lg EXCEPT ![s] = <<E("created", NoBlob)>>]
    /\ UNCHANGED <<links, base, lost>>

Start(s) ==
    /\ st[s] = "live"
    /\ Len(lg[s]) < MaxLen
    /\ ~IsOpen(lg[s])
    /\ lg' = [lg EXCEPT ![s] = Append(@, E("start", NoBlob))]
    /\ UNCHANGED <<st, links, base, lost>>

Commit(s) ==
    /\ st[s] = "live"
    /\ Len(lg[s]) < MaxLen
    /\ IsOpen(lg[s])
    /\ lg' = [lg EXCEPT ![s] = Append(@, E("commit", NoBlob))]
    /\ UNCHANGED <<st, links, base, lost>>


PutBlob(s, b) ==
    /\ st[s] = "live"
    /\ b \notin links[s]
    /\ links' = [links EXCEPT ![s] = @ \cup {b}]
    /\ UNCHANGED <<st, lg, base, lost>>


Item(s, b) ==
    /\ st[s] = "live"
    /\ Len(lg[s]) < MaxLen
    /\ IsOpen(lg[s])
    /\ b \in links[s]
    /\ lg' = [lg EXCEPT ![s] = Append(@, E("item", b))]
    /\ UNCHANGED <<st, links, base, lost>>






SetBlob(s, b) ==
    /\ st[s] = "live"
    /\ Len(lg[s]) < MaxLen
    /\ Count(lg[s], "set") = 0
    /\ b \in links[s]
    /\ lg' = [lg EXCEPT ![s] = Append(@, E("set", b))]
    /\ UNCHANGED <<st, links, base, lost>>





Fork(src, f, at) ==
    /\ st[src] = "live"
    /\ st[f] = "none"
    /\ at \in 1..Len(lg[src])
    /\ ~IsOpen(SubSeq(lg[src], 1, at))
    /\ \A i \in 2..at : lg[src][i].b # NoBlob => lg[src][i].b \in links[src]
    /\ LET copied == SubSeq(lg[src], 2, at) IN
          /\ lg' = [lg EXCEPT ![f] = <<E("created", NoBlob)>> \o copied]
          /\ base' = [base EXCEPT ![f] = copied]
    /\ links' = [links EXCEPT ![f] = links[src]]
    /\ st' = [st EXCEPT ![f] = "live"]
    /\ UNCHANGED lost


Delete(s) ==
    /\ st[s] = "live"
    /\ st' = [st EXCEPT ![s] = "deleted"]
    /\ lg' = [lg EXCEPT ![s] = <<>>]
    /\ links' = [links EXCEPT ![s] = {}]
    /\ lost' = [lost EXCEPT ![s] = {}]
    /\ UNCHANGED base


Lose(s, b) ==
    /\ st[s] = "live"
    /\ b \in links[s]
    /\ links' = [links EXCEPT ![s] = @ \ {b}]
    /\ lost' = [lost EXCEPT ![s] = @ \cup {b}]
    /\ UNCHANGED <<st, lg, base>>

Next ==
    \E s \in Ids :
        \/ Create(s)
        \/ Start(s)
        \/ Commit(s)
        \/ Delete(s)
        \/ \E b \in Blobs : PutBlob(s, b) \/ Item(s, b) \/ SetBlob(s, b) \/ Lose(s, b)
        \/ \E f \in Ids, at \in 1..MaxLen : Fork(s, f, at)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------




RefsExist ==
    \A s \in Ids : st[s] = "live" =>
        \A i \in 1..Len(lg[s]) :
            lg[s][i].b # NoBlob => lg[s][i].b \in links[s] \cup lost[s]


ForkKeepsPrefix ==
    \A f \in Ids : st[f] = "live" =>
        SubSeq(lg[f], 2, Len(base[f]) + 1) = base[f]


ForkAtBoundary == \A f \in Ids : ~IsOpen(base[f])


FirstLine == \A s \in Ids : st[s] = "live" => lg[s][1].k = "created"
=============================================================================
