---- MODULE SubscriptionTrace ----
















EXTENDS Subscription, TraceObs, Integers, Sequences, FiniteSets

VARIABLE i

Recs == {ObsTrace[n] : n \in 1..Len(ObsTrace)}
ObsSubSet == ({r.data.sub : r \in Recs} \ {0}) \cup {1}
ObsMaxSub == CHOOSE m \in ObsSubSet : \A x \in ObsSubSet : x <= m
ObsSubs == 1..ObsMaxSub
ObsKinds == {"tools", "prompts", "resources"}
KindBit(k) == CASE k = "tools" -> 1 [] k = "prompts" -> 2 [] OTHER -> 4
Bits(m) == {k \in ObsKinds : (m \div KindBit(k)) % 2 = 1}
Opens(s) == {r \in Recs : r.event = "open" /\ r.data.sub = s /\ ~r.data.ignored}
ObsAsk(s) == IF Opens(s) = {} THEN {"tools"} ELSE Bits((CHOOSE r \in Opens(s) : TRUE).data.filter)
Sent == {r.data.id : r \in {x \in Recs : x.event \in {"open", "resend"} /\ ~x.data.ignored}}
ObsMaxListens == IF Sent = {} THEN 1 ELSE Cardinality(Sent)
Idx(n) == Cardinality({m \in Sent : m <= n})
ObsStdio == \E r \in Recs : r.event \in {"crash", "restart"}

Field(packed, s) == (packed \div (2^(4 * (s - 1)))) % 16
PhaseName(n) == CASE n = 0 -> "off" [] n = 1 -> "pending" [] n = 2 -> "active" [] n = 3 -> "waiting" [] OTHER -> "ended"

OnListen(r) == r.data.id \in Sent

Step(r) ==
    LET s == r.data.sub
        n == Idx(r.data.id)
    IN CASE r.event = "open" -> Open(s)
         [] r.event = "resend" -> Resend(s)
         [] r.event = "cancel" -> Cancel(s)
         [] r.event = "ack" -> OnListen(r) /\ Ack(n, Bits(r.data.filter))
         [] r.event = "note" -> OnListen(r) /\ \E k \in Bits(r.data.filter) : Note(n, k)
         [] r.event = "final" -> OnListen(r) /\ Final(n)
         [] r.event = "lost" -> OnListen(r) /\ Lost(n)
         [] r.event = "crash" -> Crash
         [] r.event = "restart" -> Restart
         [] OTHER -> FALSE

Matches(r) ==
    /\ \A s \in Subs :
        /\ phase'[s] = PhaseName(Field(r.data.phases, s))
        /\ tries'[s] = Field(r.data.tries, s)
        /\ acked'[s] = Bits(Field(r.data.acked, s))
    /\ up' = r.data.up

TraceInit ==
    /\ Init
    /\ stdio = ObsStdio
    /\ i = 0

TraceNext ==
    /\ i < Len(ObsTrace)
    /\ LET r == ObsTrace[i + 1]
       IN /\ IF r.data.ignored THEN UNCHANGED vars ELSE Step(r)
          /\ Matches(r)
    /\ i' = i + 1


NotDone == i < Len(ObsTrace)
====
