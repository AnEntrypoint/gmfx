----------------------------- MODULE Catalog -----------------------------













EXTENDS Naturals, Sequences, FiniteSets

CONSTANT Ids

VARIABLES
    dir,
    index,
    pending,
    everDeleted

vars == <<dir, index, pending, everDeleted>>

LastOp(s) ==
    LET is == {i \in 1..Len(index) : index[i].id = s} IN
    IF is = {} THEN "none"
    ELSE index[CHOOSE i \in is : \A j \in is : j <= i].op

Indexed == {s \in Ids : LastOp(s) = "put"}
Live == {s \in Ids : dir[s] = "live"}


Listed == {s \in Indexed : dir[s] = "live"}

TypeOK ==
    /\ dir \in [Ids -> {"none", "live", "trash", "gone"}]
    /\ pending \in [Ids -> {"none", "put", "del"}]
    /\ everDeleted \subseteq Ids

Init ==
    /\ dir = [s \in Ids |-> "none"]
    /\ index = <<>>
    /\ pending = [s \in Ids |-> "none"]
    /\ everDeleted = {}


Publish(s) ==
    /\ dir[s] = "none"
    /\ dir' = [dir EXCEPT ![s] = "live"]
    /\ pending' = [pending EXCEPT ![s] = "put"]
    /\ UNCHANGED <<index, everDeleted>>

IndexPut(s) ==
    /\ pending[s] = "put"
    /\ index' = Append(index, [id |-> s, op |-> "put"])
    /\ pending' = [pending EXCEPT ![s] = "none"]
    /\ UNCHANGED <<dir, everDeleted>>


Trash(s) ==
    /\ dir[s] = "live"
    /\ pending[s] = "none"
    /\ dir' = [dir EXCEPT ![s] = "trash"]
    /\ pending' = [pending EXCEPT ![s] = "del"]
    /\ everDeleted' = everDeleted \cup {s}
    /\ UNCHANGED index

IndexDel(s) ==
    /\ pending[s] = "del"
    /\ index' = Append(index, [id |-> s, op |-> "del"])
    /\ pending' = [pending EXCEPT ![s] = "none"]
    /\ UNCHANGED <<dir, everDeleted>>

Purge(s) ==
    /\ dir[s] = "trash"
    /\ pending[s] = "none"
    /\ dir' = [dir EXCEPT ![s] = "gone"]
    /\ UNCHANGED <<index, pending, everDeleted>>






Refresh(s) ==
    /\ dir[s] = "live"
    /\ LastOp(s) # "put"
    /\ index' = Append(index, [id |-> s, op |-> "put"])
    /\ UNCHANGED <<dir, pending, everDeleted>>


Crash ==
    /\ \E s \in Ids : pending[s] # "none"
    /\ pending' = [s \in Ids |-> "none"]
    /\ UNCHANGED <<dir, index, everDeleted>>


Heal(s) ==
    /\ s \in Indexed
    /\ dir[s] # "live"
    /\ index' = Append(index, [id |-> s, op |-> "del"])
    /\ UNCHANGED <<dir, pending, everDeleted>>





Tombstoned == {s \in Ids : LastOp(s) = "del"}

Rebuild ==
    /\ LET n == Cardinality(Live)
           m == Cardinality(Tombstoned)
       IN \E order \in [1..n -> Live], gone \in [1..m -> Tombstoned] :
          /\ \A i, j \in 1..n : i # j => order[i] # order[j]
          /\ \A i, j \in 1..m : i # j => gone[i] # gone[j]
          /\ index' = [i \in 1..n |-> [id |-> order[i], op |-> "put"]]
                      \o [i \in 1..m |-> [id |-> gone[i], op |-> "del"]]
    /\ dir' = [s \in Ids |-> IF dir[s] = "trash" THEN "gone" ELSE dir[s]]
    /\ pending' = [s \in Ids |-> "none"]
    /\ UNCHANGED everDeleted

Next ==
    \/ \E s \in Ids :
          \/ Publish(s)
          \/ IndexPut(s)
          \/ Refresh(s)
          \/ Trash(s)
          \/ IndexDel(s)
          \/ Purge(s)
          \/ Heal(s)
    \/ Crash
    \/ Rebuild

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------



ListedAreLive == Listed \subseteq Live


NoResurrection ==
    \A s \in everDeleted : s \notin Listed /\ dir[s] # "live"


IndexNamesPublished ==
    \A i \in 1..Len(index) : dir[index[i].id] # "none"



RebuildIsExact == [][Rebuild => (Indexed' = Live')]_vars
=============================================================================
