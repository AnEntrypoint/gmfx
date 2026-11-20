---------------------------- MODULE CacheWarming ----------------------------

























EXTENDS Naturals

CONSTANTS
    TTL,
    Cap,
    MaxSend,
    MaxSleep,
    Bug

ASSUME /\ TTL \in 10..40 /\ Cap \in TTL..(4 * TTL)
       /\ MaxSend \in 1..TTL /\ MaxSleep \in 2..(2 * TTL)



Interval == IF Bug = "ping_at_ttl" THEN TTL ELSE TTL - TTL \div 10
Late == (TTL - (TTL - TTL \div 10)) \div 2
MaxPings == Cap \div (TTL - TTL \div 10)

Stops == {"none", "disarmed", "cap", "late", "failed", "missed"}

VARIABLES
    awake,
    sending,
    sendAge,
    armed,
    touchAge,

    reqAge,
    pings,
    inflight,
    pingAge,
    pingStale,
    pingHit,
    cacheAge,
    slept,
    evicted,
    stopped,
    staleStop,
    writes

vars == <<awake, sending, sendAge, armed, touchAge, reqAge, pings, inflight,
          pingAge, pingStale, pingHit, cacheAge, slept, evicted, stopped,
          staleStop, writes>>

Sat(n, max) == IF n > max THEN max ELSE n
Alive == cacheAge < TTL

TypeOK ==
    /\ awake \in BOOLEAN /\ sending \in BOOLEAN /\ sendAge \in 0..(TTL + 1)
    /\ armed \in BOOLEAN /\ touchAge \in 0..(TTL + 1) /\ reqAge \in 0..(Cap + TTL + 1)
    /\ pings \in 0..(MaxPings + 2) /\ inflight \in BOOLEAN /\ pingAge \in 0..1
    /\ pingStale \in BOOLEAN /\ pingHit \in BOOLEAN /\ cacheAge \in 0..TTL
    /\ slept \in BOOLEAN /\ evicted \in BOOLEAN /\ stopped \in Stops
    /\ staleStop \in BOOLEAN /\ writes \in 0..1

Init ==
    /\ awake = TRUE /\ sending = FALSE /\ sendAge = 0
    /\ armed = FALSE /\ touchAge = 0 /\ reqAge = 0 /\ pings = 0
    /\ inflight = FALSE /\ pingAge = 0 /\ pingStale = FALSE /\ pingHit = FALSE
    /\ cacheAge = TTL /\ slept = FALSE /\ evicted = FALSE
    /\ stopped = "none" /\ staleStop = FALSE /\ writes = 0



PastCap(touch, req) == Bug # "no_cap" /\ (req - touch) + Interval > Cap





Send ==
    /\ awake /\ ~sending
    /\ sending' = TRUE /\ sendAge' = 0
    /\ armed' = FALSE
    /\ stopped' = IF armed THEN "disarmed" ELSE stopped
    /\ pingStale' = (inflight \/ pingStale)
    /\ cacheAge' = 0 /\ evicted' = FALSE
    /\ UNCHANGED <<awake, touchAge, reqAge, pings, inflight, pingAge, pingHit,
                   slept, staleStop, writes>>


Complete ==
    /\ sending
    /\ sending' = FALSE
    /\ IF PastCap(sendAge, sendAge) \/ sendAge > Interval + Late
       THEN /\ armed' = FALSE
            /\ stopped' = IF sendAge > Interval + Late THEN "late" ELSE "cap"
       ELSE /\ armed' = TRUE /\ stopped' = "none"
    /\ touchAge' = sendAge /\ reqAge' = sendAge /\ pings' = 0
    /\ pingStale' = (inflight \/ pingStale)

    /\ slept' = FALSE /\ staleStop' = FALSE
    /\ UNCHANGED <<awake, sendAge, inflight, pingAge, pingHit, cacheAge, evicted, writes>>


Fail ==
    /\ sending
    /\ sending' = FALSE
    /\ UNCHANGED <<awake, sendAge, armed, touchAge, reqAge, pings, inflight,
                   pingAge, pingStale, pingHit, cacheAge, slept, evicted,
                   stopped, staleStop, writes>>



Reset ==
    /\ awake /\ armed
    /\ armed' = FALSE /\ stopped' = "disarmed"
    /\ pingStale' = (inflight \/ pingStale)
    /\ UNCHANGED <<awake, sending, sendAge, touchAge, reqAge, pings, inflight,
                   pingAge, pingHit, cacheAge, slept, evicted, staleStop, writes>>


Shutdown ==
    /\ awake
    /\ awake' = FALSE /\ armed' = FALSE /\ sending' = FALSE
    /\ inflight' = (Bug = "no_shutdown_cancel" /\ inflight)
    /\ stopped' = IF armed THEN "disarmed" ELSE stopped
    /\ UNCHANGED <<sendAge, touchAge, reqAge, pings, pingAge, pingStale,
                   pingHit, cacheAge, slept, evicted, staleStop, writes>>




CanWake ==
    /\ awake /\ ~inflight /\ touchAge >= Interval
    /\ (armed \/ (Bug = "ping_while_sending" /\ sending))

Wake ==
    /\ CanWake
    /\ IF touchAge > Interval + Late /\ Bug # "no_late_check"
       THEN /\ armed' = FALSE /\ stopped' = "late"
            /\ UNCHANGED <<inflight, pingAge, pingStale, pingHit, pings, cacheAge,
                           writes, slept, evicted>>
       ELSE /\ inflight' = TRUE /\ pingAge' = 0 /\ pingStale' = FALSE
            /\ pingHit' = Alive
            /\ pings' = Sat(pings + 1, MaxPings + 2)

            /\ cacheAge' = 0
            /\ writes' = IF ~Alive /\ ~evicted THEN 1 ELSE writes

            /\ slept' = FALSE /\ evicted' = FALSE
            /\ UNCHANGED <<armed, stopped>>
    /\ UNCHANGED <<awake, sending, sendAge, touchAge, reqAge, staleStop>>


Answer(outcome) ==
    /\ inflight
    /\ outcome \in (IF pingHit THEN {"read", "failed"} ELSE {"missed", "failed"})
    /\ inflight' = FALSE
    /\ IF pingStale /\ Bug # "stale_finish"
       THEN UNCHANGED <<armed, touchAge, stopped, staleStop>>
       ELSE IF outcome = "read"
            THEN /\ touchAge' = pingAge
                 /\ IF armed /\ PastCap(pingAge, reqAge)
                    THEN armed' = FALSE /\ stopped' = "cap"
                    ELSE UNCHANGED <<armed, stopped>>
                 /\ UNCHANGED staleStop
            ELSE /\ armed' = FALSE
                 /\ stopped' = IF armed \/ pingStale THEN outcome ELSE stopped
                 /\ staleStop' = (pingStale /\ armed)
                 /\ UNCHANGED touchAge
    /\ UNCHANGED <<awake, sending, sendAge, reqAge, pings, pingAge, pingStale,
                   pingHit, cacheAge, slept, evicted, writes>>





Urgent ==
    \/ CanWake
    \/ (inflight /\ pingAge = 1)
    \/ (sending /\ sendAge = MaxSend)

Age(d) ==
    /\ touchAge' = Sat(touchAge + d, TTL + 1)
    /\ reqAge' = Sat(reqAge + d, Cap + TTL + 1)
    /\ sendAge' = IF sending THEN Sat(sendAge + d, TTL + 1) ELSE sendAge
    /\ pingAge' = IF inflight THEN Sat(pingAge + d, 1) ELSE pingAge
    /\ cacheAge' = Sat(cacheAge + d, TTL)

Tick ==
    /\ awake /\ ~Urgent
    /\ Age(1)
    /\ UNCHANGED <<awake, sending, armed, pings, inflight, pingStale, pingHit,
                   slept, evicted, stopped, staleStop, writes>>


Sleep ==
    /\ awake /\ ~inflight /\ ~sending
    /\ \E d \in 2..MaxSleep : Age(d)
    /\ slept' = TRUE
    /\ UNCHANGED <<awake, sending, armed, pings, inflight, pingStale, pingHit,
                   evicted, stopped, staleStop, writes>>


Evict ==
    /\ awake /\ Alive
    /\ cacheAge' = TTL /\ evicted' = TRUE
    /\ UNCHANGED <<awake, sending, sendAge, armed, touchAge, reqAge, pings,
                   inflight, pingAge, pingStale, pingHit, slept, stopped,
                   staleStop, writes>>


Closed == ~awake /\ UNCHANGED vars

Next ==
    \/ Send \/ Complete \/ Fail \/ Reset \/ Shutdown
    \/ Wake \/ \E o \in {"read", "missed", "failed"} : Answer(o)
    \/ Tick \/ Sleep \/ Evict \/ Closed

Spec == Init /\ [][Next]_vars





NoWritingPing == writes = 0



KeepsAlive == (armed /\ ~slept /\ ~evicted) => Alive


PingWithinCap == [][Wake /\ inflight' => reqAge <= Cap]_vars


PingsBounded == pings <= MaxPings


NoPingWhileSending == (inflight /\ ~pingStale) => ~sending


NoPingAfterShutdown == ~awake => (~armed /\ ~inflight)


NoStaleStop == ~staleStop

=============================================================================
