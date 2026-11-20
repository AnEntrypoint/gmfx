------------------------------ MODULE Journal ------------------------------













EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS MaxEvents, MaxCrashes

VARIABLES
    alive,
    mem,
    sent,
    queue,
    durable,
    acked,
    waiting,
    passed,
    nextId,
    crashes

vars == <<alive, mem, sent, queue, durable, acked, waiting, passed, nextId, crashes>>

Ev == [id : 1..MaxEvents, barrier : BOOLEAN]

Ids(s) == {s[i].id : i \in 1..Len(s)}

IsPrefix(a, b) == Len(a) <= Len(b) /\ SubSeq(b, 1, Len(a)) = a

TypeOK ==
    /\ alive \in BOOLEAN
    /\ mem \in Seq(Ev)
    /\ sent \in 0..MaxEvents
    /\ queue \in Seq(Ev)
    /\ durable \in Seq(Ev)
    /\ acked \in 0..MaxEvents
    /\ waiting \in 0..MaxEvents
    /\ passed \subseteq 1..MaxEvents
    /\ nextId \in 1..(MaxEvents + 1)
    /\ crashes \in 0..MaxCrashes

Init ==
    /\ alive = TRUE
    /\ mem = <<>>
    /\ sent = 0
    /\ queue = <<>>
    /\ durable = <<>>
    /\ acked = 0
    /\ waiting = 0
    /\ passed = {}
    /\ nextId = 1
    /\ crashes = 0


Emit(b) ==
    /\ alive
    /\ waiting = 0
    /\ nextId <= MaxEvents
    /\ mem' = Append(mem, [id |-> nextId, barrier |-> b])
    /\ waiting' = IF b THEN Len(mem) + 1 ELSE 0
    /\ nextId' = nextId + 1
    /\ UNCHANGED <<alive, sent, queue, durable, acked, passed, crashes>>


Send ==
    /\ alive
    /\ sent < Len(mem)
    /\ queue' = Append(queue, mem[sent + 1])
    /\ sent' = sent + 1
    /\ UNCHANGED <<alive, mem, durable, acked, waiting, passed, nextId, crashes>>



Persist ==
    /\ queue # <<>>
    /\ durable' = Append(durable, Head(queue))
    /\ queue' = Tail(queue)
    /\ UNCHANGED <<alive, mem, sent, acked, waiting, passed, nextId, crashes>>


Ack ==
    /\ alive
    /\ acked < Len(durable)
    /\ acked' = acked + 1
    /\ UNCHANGED <<alive, mem, sent, queue, durable, waiting, passed, nextId, crashes>>


PassBarrier ==
    /\ alive
    /\ waiting # 0
    /\ acked >= waiting
    /\ passed' = passed \cup {mem[waiting].id}
    /\ waiting' = 0
    /\ UNCHANGED <<alive, mem, sent, queue, durable, acked, nextId, crashes>>



Reject ==
    /\ alive
    /\ queue # <<>>
    /\ queue' = <<>>
    /\ waiting' = 0
    /\ acked' = Len(durable)
    /\ sent' = Len(durable)
    /\ mem' = durable
    /\ UNCHANGED <<alive, durable, passed, nextId, crashes>>


Crash ==
    /\ alive
    /\ crashes < MaxCrashes
    /\ alive' = FALSE
    /\ mem' = <<>>
    /\ sent' = 0
    /\ acked' = 0
    /\ waiting' = 0
    /\ \E k \in 0..Len(queue) : queue' = SubSeq(queue, 1, k)
    /\ crashes' = crashes + 1
    /\ UNCHANGED <<durable, passed, nextId>>


Restore ==
    /\ ~alive
    /\ queue = <<>>
    /\ alive' = TRUE
    /\ mem' = durable
    /\ sent' = Len(durable)
    /\ acked' = Len(durable)
    /\ UNCHANGED <<queue, durable, waiting, passed, nextId, crashes>>

Next ==
    \/ \E b \in BOOLEAN : Emit(b)
    \/ Send
    \/ Persist
    \/ Ack
    \/ PassBarrier
    \/ Reject
    \/ Crash
    \/ Restore

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------




PipelineInOrder == alive => durable \o queue = SubSeq(mem, 1, sent)


KernelSeesDurable == alive => IsPrefix(durable, mem)


AckedAreDurable == acked <= Len(durable)


PassedBarriersDurable == passed \subseteq Ids(durable)


NoDuplicateEvents ==
    \A i, j \in 1..Len(durable) : durable[i].id = durable[j].id => i = j


DurableOnlyGrows == [][IsPrefix(durable, durable')]_vars

=============================================================================
