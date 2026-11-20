---------------------------- MODULE SessionLog ----------------------------










EXTENDS Naturals, Sequences

CONSTANT MaxLines

VARIABLES
    log,
    durable,
    acked,
    status

vars == <<log, durable, acked, status>>

Line(n, d) == [seq |-> n, done |-> d]

LastDone == Len(log) = 0 \/ log[Len(log)].done

TypeOK ==
    /\ log \in Seq([seq : 1..MaxLines, done : BOOLEAN])
    /\ Len(log) <= MaxLines
    /\ durable \in 0..MaxLines
    /\ acked \in 0..MaxLines
    /\ status \in {"open", "writing", "down"}

Init ==
    /\ log = <<>>
    /\ durable = 0
    /\ acked = 0
    /\ status = "open"


BeginWrite ==
    /\ status = "open"
    /\ Len(log) < MaxLines
    /\ log' = Append(log, Line(Len(log) + 1, FALSE))
    /\ status' = "writing"
    /\ UNCHANGED <<durable, acked>>


FinishWrite ==
    /\ status = "writing"
    /\ log' = [log EXCEPT ![Len(log)].done = TRUE]
    /\ status' = "open"
    /\ UNCHANGED <<durable, acked>>


Fsync ==
    /\ status = "open"
    /\ durable' = Len(log)
    /\ acked' = Len(log)
    /\ UNCHANGED <<log, status>>


ProcessCrash ==
    /\ status \in {"open", "writing"}
    /\ status' = "down"
    /\ UNCHANGED <<log, durable, acked>>





PowerLoss ==
    /\ \E k \in durable..Len(log), torn \in BOOLEAN :
          LET kept == SubSeq(log, 1, k) IN
          log' = IF torn /\ k > durable
                    THEN [kept EXCEPT ![k].done = FALSE]
                    ELSE kept
    /\ status' = "down"
    /\ UNCHANGED <<durable, acked>>


Recover ==
    /\ status = "down"
    /\ LET repaired == IF LastDone THEN log ELSE SubSeq(log, 1, Len(log) - 1)
       IN /\ log' = repaired
          /\ durable' = Len(repaired)
    /\ status' = "open"
    /\ UNCHANGED acked

Next ==
    \/ BeginWrite
    \/ FinishWrite
    \/ Fsync
    \/ ProcessCrash
    \/ PowerLoss
    \/ Recover

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------



SeqContiguous == \A i \in 1..Len(log) : log[i].seq = i


OnlyTailTorn == \A i \in 1..(Len(log) - 1) : log[i].done


AckedSurvive ==
    /\ acked <= durable
    /\ durable <= Len(log)
    /\ \A i \in 1..acked : log[i].done


OpenIsClean == status = "open" => LastDone




=============================================================================
