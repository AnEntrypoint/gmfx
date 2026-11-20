---------------------------- MODULE Lifecycle ----------------------------












EXTENDS Naturals

CONSTANT Ids

Steps == {"idle", "mem", "tmpdir", "written", "synced", "renamed", "done", "dead"}

VARIABLES
    step,
    where,
    line1,
    acked

vars == <<step, where, line1, acked>>

TypeOK ==
    /\ step \in [Ids -> Steps]
    /\ where \in [Ids -> {"none", "tmp", "visible"}]
    /\ line1 \in [Ids -> {"none", "cached", "durable"}]
    /\ acked \in [Ids -> BOOLEAN]

Init ==
    /\ step = [s \in Ids |-> "idle"]
    /\ where = [s \in Ids |-> "none"]
    /\ line1 = [s \in Ids |-> "none"]
    /\ acked = [s \in Ids |-> FALSE]

Advance(s, from, to) ==
    /\ step[s] = from
    /\ step' = [step EXCEPT ![s] = to]

OpenNew(s) ==
    /\ Advance(s, "idle", "mem")
    /\ UNCHANGED <<where, line1, acked>>

MkTmp(s) ==
    /\ Advance(s, "mem", "tmpdir")
    /\ where' = [where EXCEPT ![s] = "tmp"]
    /\ UNCHANGED <<line1, acked>>

WriteLine1(s) ==
    /\ Advance(s, "tmpdir", "written")
    /\ line1' = [line1 EXCEPT ![s] = "cached"]
    /\ UNCHANGED <<where, acked>>

FsyncLog(s) ==
    /\ Advance(s, "written", "synced")
    /\ line1' = [line1 EXCEPT ![s] = "durable"]
    /\ UNCHANGED <<where, acked>>

Rename(s) ==
    /\ Advance(s, "synced", "renamed")
    /\ where' = [where EXCEPT ![s] = "visible"]
    /\ UNCHANGED <<line1, acked>>


FsyncDirAndAck(s) ==
    /\ Advance(s, "renamed", "done")
    /\ acked' = [acked EXCEPT ![s] = TRUE]
    /\ UNCHANGED <<where, line1>>


ProcessCrash ==
    /\ \E s \in Ids : step[s] \notin {"idle", "done", "dead"}
    /\ step' = [s \in Ids |-> IF step[s] \in {"idle", "done"} THEN step[s] ELSE "dead"]
    /\ UNCHANGED <<where, line1, acked>>






PowerLoss ==
    \E lose \in [Ids -> BOOLEAN], gone \in [Ids -> BOOLEAN], keep \in [Ids -> BOOLEAN] :
        LET w == [s \in Ids |->
                    CASE step[s] = "renamed" /\ lose[s] -> IF gone[s] THEN "none" ELSE "tmp"
                      [] where[s] = "tmp" /\ step[s] # "done" /\ lose[s] -> "none"
                      [] OTHER -> where[s]]
        IN /\ where' = w
           /\ line1' = [s \in Ids |->
                          CASE w[s] = "none"                  -> "none"
                            [] line1[s] = "cached" /\ keep[s] -> "durable"
                            [] line1[s] = "cached"            -> "none"
                            [] OTHER                          -> line1[s]]
           /\ step' = [s \in Ids |->
                          IF step[s] \in {"idle", "done"} THEN step[s] ELSE "dead"]
           /\ UNCHANGED acked


Sweep(s) ==
    /\ step[s] = "dead"
    /\ where[s] = "tmp"
    /\ where' = [where EXCEPT ![s] = "none"]
    /\ line1' = [line1 EXCEPT ![s] = "none"]
    /\ UNCHANGED <<step, acked>>

Next ==
    \/ \E s \in Ids :
          \/ OpenNew(s)
          \/ MkTmp(s)
          \/ WriteLine1(s)
          \/ FsyncLog(s)
          \/ Rename(s)
          \/ FsyncDirAndAck(s)
          \/ Sweep(s)
    \/ ProcessCrash
    \/ PowerLoss

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------



VisibleHasLine1 == \A s \in Ids : where[s] = "visible" => line1[s] = "durable"


AckedIsVisible == \A s \in Ids : acked[s] => where[s] = "visible"


NothingBeforeFirstTurn ==
    \A s \in Ids : step[s] \in {"idle", "mem"} => where[s] = "none"
=============================================================================
