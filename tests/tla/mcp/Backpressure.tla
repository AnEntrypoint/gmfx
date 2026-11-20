---- MODULE Backpressure ----

















EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Readers,
    Sizes,
    Allowance

None == "none"
Max == CHOOSE m \in Sizes : \A s \in Sizes : s <= m

ASSUME Allowance \in Nat /\ 0 < Allowance /\ Allowance < Max /\ None \notin Readers

VARIABLES
    want,
    got,
    line,
    large,
    counted,
    queue,
    used

vars == <<want, got, line, large, counted, queue, used>>

RECURSIVE Total(_)
Total(s) == IF s = <<>> THEN 0 ELSE Head(s) + Total(Tail(s))

RECURSIVE Reading(_)
Reading(rs) == IF rs = {} THEN 0 ELSE LET r == CHOOSE x \in rs : TRUE IN got[r] + Reading(rs \ {r})

Without(s, r) == SelectSeq(s, LAMBDA x : x # r)
InLine(r) == \E i \in 1..Len(line) : line[i] = r


First(r) == line # <<>> /\ Head(line) = r

Small(r) == want[r] > 0 /\ want[r] <= Allowance


Waits(r) ==
    \/ Small(r) /\ got[r] = want[r]
    \/ want[r] > Allowance /\ got[r] = Allowance /\ large # r




Reserve == IF large = None THEN 0 ELSE Allowance + 1

TypeOK ==
    /\ want \in [Readers -> {0} \cup Sizes]
    /\ got \in [Readers -> 0..Max]
    /\ line \in Seq(Readers)
    /\ large \in Readers \cup {None}
    /\ counted \in Nat
    /\ queue \in Seq(Sizes)
    /\ used \in Nat

Init ==
    /\ want = [r \in Readers |-> 0]
    /\ got = [r \in Readers |-> 0]
    /\ line = <<>>
    /\ large = None
    /\ counted = 0
    /\ queue = <<>>
    /\ used = 0


Start(r) ==
    /\ want[r] = 0
    /\ \E s \in Sizes : want' = [want EXCEPT ![r] = s]
    /\ UNCHANGED <<got, line, large, counted, queue, used>>


ReadFree(r) ==
    /\ want[r] > 0 /\ got[r] < want[r] /\ got[r] < Allowance
    /\ got' = [got EXCEPT ![r] = @ + 1]
    /\ UNCHANGED <<want, line, large, counted, queue, used>>


Join(r) ==
    /\ Waits(r) /\ ~InLine(r)
    /\ line' = Append(line, r)
    /\ UNCHANGED <<want, got, large, counted, queue, used>>


Claim(r) ==
    /\ want[r] > Allowance /\ got[r] = Allowance
    /\ First(r) /\ large = None
    /\ large' = r
    /\ line' = Tail(line)
    /\ UNCHANGED <<want, got, counted, queue, used>>


ReadCounted(r) ==
    /\ large = r /\ got[r] < want[r]
    /\ used + 1 <= Max
    /\ got' = [got EXCEPT ![r] = @ + 1]
    /\ counted' = counted + 1
    /\ used' = used + 1
    /\ UNCHANGED <<want, line, large, queue>>


PostSmall(r) ==
    /\ Small(r) /\ got[r] = want[r]
    /\ First(r) /\ used + want[r] + Reserve <= Max
    /\ queue' = Append(queue, want[r])
    /\ used' = used + want[r]
    /\ want' = [want EXCEPT ![r] = 0]
    /\ got' = [got EXCEPT ![r] = 0]
    /\ line' = Tail(line)
    /\ UNCHANGED <<large, counted>>


PostLarge(r) ==
    /\ large = r /\ got[r] = want[r]
    /\ used - counted + want[r] <= Max
    /\ queue' = Append(queue, want[r])
    /\ used' = used - counted + want[r]
    /\ counted' = 0
    /\ large' = None
    /\ want' = [want EXCEPT ![r] = 0]
    /\ got' = [got EXCEPT ![r] = 0]
    /\ UNCHANGED line

Cancel(r) ==
    /\ want[r] > 0
    /\ want' = [want EXCEPT ![r] = 0]
    /\ got' = [got EXCEPT ![r] = 0]
    /\ line' = Without(line, r)
    /\ IF large = r
       THEN /\ large' = None
            /\ counted' = 0
            /\ used' = used - counted
       ELSE UNCHANGED <<large, counted, used>>
    /\ UNCHANGED queue

Take ==
    /\ queue # <<>>
    /\ used' = used - Head(queue)
    /\ queue' = Tail(queue)
    /\ UNCHANGED <<want, got, line, large, counted>>

Next ==
    \/ \E r \in Readers :
        Start(r) \/ ReadFree(r) \/ Join(r) \/ Claim(r) \/ ReadCounted(r) \/ PostSmall(r) \/ PostLarge(r) \/ Cancel(r)
    \/ Take



Fair(r) ==
    /\ WF_vars(ReadFree(r)) /\ WF_vars(Join(r)) /\ WF_vars(Claim(r))
    /\ WF_vars(ReadCounted(r)) /\ WF_vars(PostSmall(r)) /\ WF_vars(PostLarge(r))

Spec == Init /\ [][Next]_vars /\ WF_vars(Take) /\ \A r \in Readers : Fair(r)





UsedIsCounted == used = Total(queue) + counted


CountedIsLarge == IF large = None THEN counted = 0 ELSE counted = got[large] - Allowance


OneLargeRead == \A r \in Readers : got[r] > Allowance => large = r


Bounded == used <= Max


HeldIsBounded == Total(queue) + Reading(Readers) <= Max + Cardinality(Readers) * Allowance


LineIsWaiters ==
    /\ \A i \in 1..Len(line) : Waits(line[i])
    /\ \A i, j \in 1..Len(line) : i # j => line[i] # line[j]





EveryMessagePosted == \A r \in Readers : want[r] > 0 ~> want[r] = 0
====
