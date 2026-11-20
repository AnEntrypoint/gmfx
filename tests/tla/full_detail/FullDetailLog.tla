---- MODULE FullDetailLog ----















EXTENDS Naturals, Sequences

CONSTANTS MaxCalls, MaxSteer, RecordsAfterSteering

ASSUME MaxCalls \in Nat /\ MaxSteer \in Nat /\ RecordsAfterSteering \in BOOLEAN

VARIABLES
    calls,
    steer,
    stamps,
    last,
    grown

vars == <<calls, steer, stamps, last, grown>>

Init ==
    /\ calls = 0
    /\ steer = 0
    /\ stamps = <<>>
    /\ last = <<>>
    /\ grown = TRUE

Settle ==
    /\ calls < MaxCalls
    /\ calls' = calls + 1
    /\ UNCHANGED <<steer, stamps, last, grown>>

Steer ==
    /\ steer < MaxSteer
    /\ steer' = steer + 1
    /\ UNCHANGED <<calls, stamps, last, grown>>

Rec(i) == [t |-> "rec", n |-> i]
Msg(j) == [t |-> "msg", n |-> j]



RECURSIVE Lay(_, _, _, _, _)
Lay(st, c, s, i, j) ==
    IF i > c /\ j > s THEN <<>>
    ELSE IF i <= c /\ (j > s \/ (~RecordsAfterSteering /\ st[i] < j))
         THEN <<Rec(i)>> \o Lay(st, c, s, i + 1, j)
         ELSE <<Msg(j)>> \o Lay(st, c, s, i, j + 1)



Save ==
    LET st == stamps \o [k \in 1..(calls - Len(stamps)) |-> steer]
        log == Lay(st, calls, steer, 1, 1)
    IN /\ stamps' = st
       /\ grown' = (grown /\ Len(log) >= Len(last) /\ SubSeq(log, 1, Len(last)) = last)
       /\ last' = log
       /\ UNCHANGED <<calls, steer>>

Next == Settle \/ Steer \/ Save

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ calls \in 0..MaxCalls
    /\ steer \in 0..MaxSteer
    /\ Len(stamps) <= calls



AppendOnly == grown
====
