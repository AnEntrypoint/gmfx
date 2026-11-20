---------------------------- MODULE Subagents ----------------------------


















EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS Children, MaxWork

VARIABLES
    plog,
    childLog,
    thread,
    up,
    repairing

vars == <<plog, childLog, thread, up, repairing>>

Outcomes == {"ok", "failed", "cancelled", "interrupted", "lost"}

Count(s, k, c) == Cardinality({i \in 1..Len(s) : s[i].k = k /\ s[i].c = c})
Works(c) == Count(plog, "spawned", c)
Unfinished(c) == Works(c) > Count(plog, "finished", c)
Spawned(c) == Works(c) > 0

TypeOK ==
    /\ \A i \in 1..Len(plog) :
          /\ plog[i].k \in {"spawned", "finished"}
          /\ plog[i].c \in Children
          /\ plog[i].w \in 1..MaxWork
          /\ plog[i].o \in Outcomes \cup {"none"}
    /\ childLog \in [Children -> BOOLEAN]
    /\ thread \in [Children -> {"none", "starting", "running"}]
    /\ up \in BOOLEAN
    /\ repairing \in BOOLEAN

Init ==
    /\ plog = <<>>
    /\ childLog = [c \in Children |-> FALSE]
    /\ thread = [c \in Children |-> "none"]
    /\ up = TRUE
    /\ repairing = FALSE

Normal == up /\ ~repairing



Spawn(c) ==
    /\ Normal
    /\ ~Unfinished(c)
    /\ Works(c) < MaxWork
    /\ plog' = Append(plog, [k |-> "spawned", c |-> c, w |-> Works(c) + 1, o |-> "none"])
    /\ thread' = [thread EXCEPT ![c] = "starting"]
    /\ UNCHANGED <<childLog, up, repairing>>


ChildStart(c) ==
    /\ Normal
    /\ thread[c] = "starting"
    /\ childLog' = [childLog EXCEPT ![c] = TRUE]
    /\ thread' = [thread EXCEPT ![c] = "running"]
    /\ UNCHANGED <<plog, up, repairing>>


ChildFinish(c) ==
    /\ Normal
    /\ thread[c] = "running"
    /\ \E o \in {"ok", "failed"} :
          plog' = Append(plog, [k |-> "finished", c |-> c, w |-> Works(c), o |-> o])
    /\ thread' = [thread EXCEPT ![c] = "none"]
    /\ UNCHANGED <<childLog, up, repairing>>


Cancel(c) ==
    /\ Normal
    /\ thread[c] \in {"starting", "running"}
    /\ plog' = Append(plog, [k |-> "finished", c |-> c, w |-> Works(c), o |-> "cancelled"])
    /\ thread' = [thread EXCEPT ![c] = "none"]
    /\ UNCHANGED <<childLog, up, repairing>>


Crash ==
    /\ up
    /\ up' = FALSE
    /\ thread' = [c \in Children |-> "none"]
    /\ repairing' = FALSE
    /\ UNCHANGED <<plog, childLog>>


Reopen ==
    /\ ~up
    /\ up' = TRUE
    /\ repairing' = TRUE
    /\ UNCHANGED <<plog, childLog, thread>>

RepairChild(c) ==
    /\ up
    /\ repairing
    /\ Unfinished(c)
    /\ plog' = Append(plog, [k |-> "finished", c |-> c, w |-> Works(c),
                             o |-> IF childLog[c] THEN "interrupted" ELSE "lost"])
    /\ UNCHANGED <<childLog, thread, up, repairing>>

RepairDone ==
    /\ up
    /\ repairing
    /\ \A c \in Children : ~Unfinished(c)
    /\ repairing' = FALSE
    /\ UNCHANGED <<plog, childLog, thread, up>>

Next ==
    \/ \E c \in Children :
          \/ Spawn(c)
          \/ ChildStart(c)
          \/ ChildFinish(c)
          \/ Cancel(c)
          \/ RepairChild(c)
    \/ Crash
    \/ Reopen
    \/ RepairDone

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------



OneOpenWork ==
    \A c \in Children :
        Count(plog, "finished", c) <= Works(c) /\ Works(c) <= Count(plog, "finished", c) + 1



FinishClosesOpenWork ==
    \A i \in 1..Len(plog) :
        plog[i].k = "finished" =>
            LET p == SubSeq(plog, 1, i - 1) IN
                /\ Count(p, "spawned", plog[i].c) = Count(p, "finished", plog[i].c) + 1
                /\ plog[i].w = Count(p, "spawned", plog[i].c)


NoOrphanChild == \A c \in Children : childLog[c] => Spawned(c)




LostMeansNoLog ==
    [][\A i \in (Len(plog) + 1)..Len(plog') :
          (plog'[i].k = "finished" /\ plog'[i].o = "lost") => ~childLog[plog'[i].c]]_vars



NoIndeterminate ==
    Normal => \A c \in Children :
        Unfinished(c) => thread[c] \in {"starting", "running"}
=============================================================================
