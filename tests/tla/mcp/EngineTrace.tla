---- MODULE EngineTrace ----















EXTENDS Engine, TraceObs, Integers, Sequences, FiniteSets

VARIABLE i

Recs == {ObsTrace[k] : k \in 1..Len(ObsTrace)}
ObsNs == {r.data.n : r \in Recs} \ {0}
ObsMaxN == IF ObsNs = {} THEN 1 ELSE CHOOSE m \in ObsNs : \A x \in ObsNs : x <= m
ObsCalls == 1..ObsMaxN
ObsMaxHost == Cardinality({k \in 1..Len(ObsTrace) : ObsTrace[k].event = "drop"})
OneServer == {1}
OnlyOwner(c) == 1

PhaseName(k) == CASE k = 0 -> "idle" [] k = 1 -> "connecting" [] k = 2 -> "ready" [] k = 3 -> "backoff" [] OTHER -> "failed"
StateName(k) == CASE k = 0 -> "none" [] k = 1 -> "waiting" [] k = 2 -> "sent" [] OTHER -> "done"

Step(r) ==
    LET n == r.data.n
    IN CASE r.event = "ask" -> Ask(n, r.data.allowed)
         [] r.event = "need" -> Need(1)
         [] r.event = "cancel" -> Cancel(n)
         [] r.event = "drop" -> Drop(1, r.data.keep)
         [] r.event = "connect" -> Connect(1)
         [] r.event = "up" -> Up(1)
         [] r.event = "down" -> Down(1)
         [] r.event = "backoff_over" -> BackoffOver(1)
         [] r.event = "stable" -> Stable(1)
         [] r.event = "answer" -> Answer(n)
         [] OTHER -> FALSE

Matches(r) ==
    /\ phase'[1] = PhaseName(r.data.phase)
    /\ attempts'[1] = r.data.attempts
    /\ need'[1] = r.data.need
    /\ Cardinality({c \in Calls : call'[c] = "waiting"}) = r.data.waiting
    /\ Cardinality({c \in Calls : call'[c] = "sent"}) = r.data.sent
    /\ r.data.n # 0 => call'[r.data.n] = StateName(r.data.state)
    /\ retry'[1] = r.data.retry

TraceInit ==
    /\ Init
    /\ i = 0

TraceNext ==
    /\ i < Len(ObsTrace)
    /\ LET r == ObsTrace[i + 1]
       IN /\ IF r.data.ignored THEN UNCHANGED vars ELSE Step(r)
          /\ Matches(r)
    /\ i' = i + 1


NotDone == i < Len(ObsTrace)
====
