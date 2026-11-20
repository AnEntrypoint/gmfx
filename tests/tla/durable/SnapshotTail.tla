---------------------------- MODULE SnapshotTail ----------------------------


















EXTENDS Naturals, Sequences

CONSTANTS Vals, MaxLen

VARIABLES
    log,
    dlen,
    snaps,
    latest,
    trimmed

vars == <<log, dlen, snaps, latest, trimmed>>

Empty == [n |-> 0, last |-> 0]

StepState(st, v) == [n |-> st.n + 1, last |-> v]

RECURSIVE FoldFrom(_, _, _)
FoldFrom(st, s, i) ==
    IF i > Len(s) THEN st ELSE FoldFrom(StepState(st, s[i]), s, i + 1)

Fold(s) == FoldFrom(Empty, s, 1)


RestoreFrom(snap) == FoldFrom(snap.state, log, snap.at + 1)

State == [n : 0..MaxLen, last : Vals \cup {0}]

TypeOK ==
    /\ log \in Seq(Vals)
    /\ Len(log) <= MaxLen
    /\ dlen \in 0..Len(log)
    /\ snaps \subseteq [at : 0..MaxLen, state : State]
    /\ latest \in [at : 0..MaxLen, state : State]
    /\ trimmed \in 0..MaxLen

Init ==
    /\ log = <<>>
    /\ dlen = 0
    /\ snaps = {}
    /\ latest = [at |-> 0, state |-> Empty]
    /\ trimmed = 0


Emit(v) ==
    /\ Len(log) < MaxLen
    /\ log' = Append(log, v)
    /\ UNCHANGED <<dlen, snaps, latest, trimmed>>


Persist ==
    /\ dlen < Len(log)
    /\ dlen' = dlen + 1
    /\ UNCHANGED <<log, snaps, latest, trimmed>>


Snapshot ==
    /\ \E at \in 0..dlen :
        snaps' = snaps \cup {[at |-> at, state |-> Fold(SubSeq(log, 1, at))]}
    /\ UNCHANGED <<log, dlen, latest, trimmed>>



Offer ==
    /\ \E s \in snaps :
        IF s.at > latest.at
        THEN /\ latest' = s
             /\ trimmed' = s.at
        ELSE UNCHANGED <<latest, trimmed>>
    /\ UNCHANGED <<log, dlen, snaps>>


Crash ==
    /\ dlen < Len(log)
    /\ log' = SubSeq(log, 1, dlen)
    /\ UNCHANGED <<dlen, snaps, latest, trimmed>>

Next ==
    \/ \E v \in Vals : Emit(v)
    \/ Persist
    \/ Snapshot
    \/ Offer
    \/ Crash

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------



SnapshotNotAhead == \A s \in snaps : s.at <= Len(log)


ResumeEqualsFullReplay == \A s \in snaps : RestoreFrom(s) = Fold(log)



SnapshotMatchesPrefix ==
    \A s \in snaps : s.at <= Len(log) /\ s.state = Fold(SubSeq(log, 1, s.at))


SnapshotsMoveForward == latest.at = trimmed



LoadEqualsFullReplay == FoldFrom(latest.state, log, trimmed + 1) = Fold(log)

=============================================================================
