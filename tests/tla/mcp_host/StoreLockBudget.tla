---- MODULE StoreLockBudget ----





















EXTENDS Naturals

CONSTANTS
    Holders,
    CallMax,
    MaxCalls,
    Budget,
    Slack,
    MaxSleep

VARIABLES
    awake, real,
    slept,
    owner,
    state,
    needs,
    calls,
    inCall,
    callAt,
    stamped,
    lockStamp,
    frozen,
    waiter,
    wStart

vars == <<awake, real, slept, owner, state, needs, calls, inCall, callAt,
          stamped, lockStamp, frozen, waiter, wStart>>


WClock == awake

Max(a, b) == IF a > b THEN a ELSE b


Deadline == Max(lockStamp, wStart) + Budget + Slack

Live(h) == owner = h /\ ~frozen[h]


CallOver(h) == inCall[h] /\ awake - callAt[h] >= CallMax

TypeOK ==
    /\ owner \in Holders \cup {"none"}
    /\ state \in [Holders -> {"ready", "holding", "done"}]
    /\ waiter \in {"waiting", "got", "gaveup"}

Init ==
    /\ awake = 0 /\ real = 0 /\ slept = FALSE

    /\ owner \in Holders
    /\ state = [h \in Holders |-> IF h = owner THEN "holding" ELSE "ready"]
    /\ needs \in [Holders -> 1..MaxCalls]
    /\ calls = [h \in Holders |-> 0]
    /\ inCall = [h \in Holders |-> FALSE]
    /\ callAt = [h \in Holders |-> 0]
    /\ stamped = [h \in Holders |-> h = owner]
    /\ lockStamp = 0
    /\ frozen = [h \in Holders |-> FALSE]
    /\ waiter = "waiting" /\ wStart = 0


Acquire(h) ==
    /\ owner = "none" /\ state[h] = "ready" /\ waiter = "waiting"
    /\ owner' = h
    /\ state' = [state EXCEPT ![h] = "holding"]
    /\ UNCHANGED <<awake, real, slept, needs, calls, inCall, callAt, stamped, lockStamp, frozen, waiter, wStart>>


WriteStamp(h) ==
    /\ Live(h) /\ ~stamped[h] /\ ~inCall[h] /\ calls[h] < needs[h]
    /\ stamped' = [stamped EXCEPT ![h] = TRUE]
    /\ lockStamp' = WClock
    /\ UNCHANGED <<awake, real, slept, owner, state, needs, calls, inCall, callAt, frozen, waiter, wStart>>

StartCall(h) ==
    /\ Live(h) /\ stamped[h] /\ ~inCall[h] /\ calls[h] < needs[h]
    /\ inCall' = [inCall EXCEPT ![h] = TRUE]
    /\ callAt' = [callAt EXCEPT ![h] = awake]
    /\ stamped' = [stamped EXCEPT ![h] = FALSE]
    /\ UNCHANGED <<awake, real, slept, owner, state, needs, calls, lockStamp, frozen, waiter, wStart>>


EndCall(h) ==
    /\ Live(h) /\ inCall[h] /\ ~CallOver(h)
    /\ inCall' = [inCall EXCEPT ![h] = FALSE]
    /\ calls' = [calls EXCEPT ![h] = @ + 1]
    /\ UNCHANGED <<awake, real, slept, owner, state, needs, callAt, stamped, lockStamp, frozen, waiter, wStart>>

Finish(h) ==
    /\ Live(h) /\ ~inCall[h] /\ calls[h] = needs[h]
    /\ owner' = "none"
    /\ state' = [state EXCEPT ![h] = "done"]
    /\ UNCHANGED <<awake, real, slept, needs, calls, inCall, callAt, stamped, lockStamp, frozen, waiter, wStart>>


Cut(h) ==
    /\ Live(h) /\ CallOver(h)
    /\ owner' = "none"
    /\ state' = [state EXCEPT ![h] = "done"]
    /\ inCall' = [inCall EXCEPT ![h] = FALSE]
    /\ UNCHANGED <<awake, real, slept, needs, calls, callAt, stamped, lockStamp, frozen, waiter, wStart>>

Freeze(h) ==
    /\ Live(h)
    /\ frozen' = [frozen EXCEPT ![h] = TRUE]
    /\ UNCHANGED <<awake, real, slept, owner, state, needs, calls, inCall, callAt, stamped, lockStamp, waiter, wStart>>

Get ==
    /\ waiter = "waiting" /\ owner = "none"
    /\ waiter' = "got"
    /\ UNCHANGED <<awake, real, slept, owner, state, needs, calls, inCall, callAt, stamped, lockStamp, frozen, wStart>>

GiveUp ==
    /\ waiter = "waiting" /\ owner # "none" /\ WClock >= Deadline
    /\ waiter' = "gaveup"
    /\ UNCHANGED <<awake, real, slept, owner, state, needs, calls, inCall, callAt, stamped, lockStamp, frozen, wStart>>



Due ==
    \/ \E h \in Holders : Live(h) /\ (CallOver(h) \/ ~inCall[h])
    \/ owner = "none"
    \/ WClock >= Deadline

Tick ==
    /\ waiter = "waiting" /\ ~Due
    /\ awake' = awake + 1 /\ real' = real + 1
    /\ UNCHANGED <<slept, owner, state, needs, calls, inCall, callAt, stamped, lockStamp, frozen, waiter, wStart>>


Sleep ==
    /\ waiter = "waiting" /\ MaxSleep > 0 /\ ~slept
    /\ \E d \in 1..MaxSleep : real' = real + d
    /\ slept' = TRUE
    /\ UNCHANGED <<awake, owner, state, needs, calls, inCall, callAt, stamped, lockStamp, frozen, waiter, wStart>>

Next ==
    \/ \E h \in Holders : Acquire(h) \/ WriteStamp(h) \/ StartCall(h) \/ EndCall(h) \/ Finish(h) \/ Cut(h) \/ Freeze(h)
    \/ Get \/ GiveUp \/ Tick \/ Sleep

Spec == Init /\ [][Next]_vars

NoGiveUpOnLiveHolder == waiter = "gaveup" => (owner # "none" /\ frozen[owner])
====
