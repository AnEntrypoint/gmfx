---------------------------- MODULE WriterLock ----------------------------











EXTENDS Naturals, Sequences

CONSTANTS Procs, Threads, MaxLines, None

VARIABLES
    holder,
    alive,
    opened,
    nextSeq,
    mutex,
    file

vars == <<holder, alive, opened, nextSeq, mutex, file>>

TypeOK ==
    /\ holder \in Procs \cup {None}
    /\ alive \in [Procs -> BOOLEAN]
    /\ opened \in [Procs -> BOOLEAN]
    /\ nextSeq \in [Procs -> 1..(MaxLines + 1)]
    /\ mutex \in [Procs -> Threads \cup {None}]
    /\ file \in Seq([seq : 1..MaxLines, by : Procs])

Init ==
    /\ holder = None
    /\ alive = [p \in Procs |-> TRUE]
    /\ opened = [p \in Procs |-> FALSE]
    /\ nextSeq = [p \in Procs |-> 1]
    /\ mutex = [p \in Procs |-> None]
    /\ file = <<>>



Open(p) ==
    /\ alive[p]
    /\ ~opened[p]
    /\ holder = None
    /\ holder' = p
    /\ opened' = [opened EXCEPT ![p] = TRUE]
    /\ nextSeq' = [nextSeq EXCEPT ![p] = Len(file) + 1]
    /\ UNCHANGED <<alive, mutex, file>>


Acquire(p, t) ==
    /\ alive[p]
    /\ opened[p]
    /\ mutex[p] = None
    /\ mutex' = [mutex EXCEPT ![p] = t]
    /\ UNCHANGED <<holder, alive, opened, nextSeq, file>>


WriteAndRelease(p, t) ==
    /\ alive[p]
    /\ opened[p]
    /\ mutex[p] = t
    /\ Len(file) < MaxLines
    /\ file' = Append(file, [seq |-> nextSeq[p], by |-> p])
    /\ nextSeq' = [nextSeq EXCEPT ![p] = @ + 1]
    /\ mutex' = [mutex EXCEPT ![p] = None]
    /\ UNCHANGED <<holder, alive, opened>>


Close(p) ==
    /\ alive[p]
    /\ opened[p]
    /\ mutex[p] = None
    /\ holder = p
    /\ holder' = None
    /\ opened' = [opened EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<alive, nextSeq, mutex, file>>


Crash(p) ==
    /\ alive[p]
    /\ alive' = [alive EXCEPT ![p] = FALSE]
    /\ opened' = [opened EXCEPT ![p] = FALSE]
    /\ mutex' = [mutex EXCEPT ![p] = None]
    /\ holder' = IF holder = p THEN None ELSE holder
    /\ UNCHANGED <<nextSeq, file>>

Restart(p) ==
    /\ ~alive[p]
    /\ alive' = [alive EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<holder, opened, nextSeq, mutex, file>>

Next ==
    \E p \in Procs :
        \/ Open(p)
        \/ Close(p)
        \/ Crash(p)
        \/ Restart(p)
        \/ \E t \in Threads : Acquire(p, t) \/ WriteAndRelease(p, t)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------



OneWriter == \A p, q \in Procs : opened[p] /\ opened[q] => p = q


OnlyHolderOpen == \A p \in Procs : opened[p] => holder = p


MutexInsideOpenSession == \A p \in Procs : mutex[p] # None => opened[p]



SeqIsPosition == \A i \in 1..Len(file) : file[i].seq = i
=============================================================================
