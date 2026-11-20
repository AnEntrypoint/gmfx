---- MODULE AuthGate ----




















EXTENDS Naturals

CONSTANTS
    Keys,
    MaxGen

ASSUME MaxGen \in Nat \ {0}

Phases == {"idle", "sent", "waiting", "done", "needs_sign_in", "failed", "cancelled"}

VARIABLES
    gen,
    held,
    refreshable,
    rt,
    inflight,
    req,

    valid,
    serverRt,
    deadRt,

    usedRt,
    sends,
    rejectedG

vars == <<gen, held, refreshable, rt, inflight, req, valid, serverRt, deadRt, usedRt, sends, rejectedG>>

Init ==
    /\ gen = 0
    /\ held = FALSE
    /\ refreshable = FALSE
    /\ rt = 0
    /\ inflight = 0
    /\ req = [k \in Keys |-> [phase |-> "idle", g |-> 0, again |-> FALSE]]
    /\ valid \in {{}, {0}}
    /\ serverRt = 0
    /\ deadRt = {}
    /\ usedRt = 0
    /\ sends = [k \in Keys |-> 0]
    /\ rejectedG = [k \in Keys |-> 0]

Token == IF held THEN gen ELSE 0





Send(k, expiring) ==
    /\ req[k].phase = "idle"
    /\ IF inflight > 0 \/ (expiring /\ held /\ refreshable)
       THEN /\ req' = [req EXCEPT ![k].phase = "waiting"]
            /\ IF inflight = 0
               THEN inflight' = 1 /\ usedRt' = rt
               ELSE UNCHANGED <<inflight, usedRt>>
            /\ UNCHANGED sends
       ELSE /\ req' = [req EXCEPT ![k].phase = "sent", ![k].g = Token]
            /\ sends' = [sends EXCEPT ![k] = @ + 1]
            /\ UNCHANGED <<inflight, usedRt>>
    /\ UNCHANGED <<gen, held, refreshable, rt, valid, serverRt, deadRt, rejectedG>>


Accept(k) ==
    /\ req[k].phase = "sent"
    /\ req[k].g \in valid
    /\ req' = [req EXCEPT ![k].phase = "done"]
    /\ UNCHANGED <<gen, held, refreshable, rt, inflight, valid, serverRt, deadRt, usedRt, sends, rejectedG>>


Reject(k) ==
    /\ req[k].phase = "sent"
    /\ req[k].g \notin valid
    /\ rejectedG' = [rejectedG EXCEPT ![k] = req[k].g]
    /\ IF req[k].again
       THEN /\ req' = [req EXCEPT ![k].phase = "needs_sign_in"]
            /\ UNCHANGED <<inflight, usedRt, sends>>
       ELSE IF Token > req[k].g
       THEN
            /\ req' = [req EXCEPT ![k].g = Token, ![k].again = TRUE]
            /\ sends' = [sends EXCEPT ![k] = @ + 1]
            /\ UNCHANGED <<inflight, usedRt>>
       ELSE IF inflight > 0
       THEN /\ req' = [req EXCEPT ![k].phase = "waiting", ![k].again = TRUE]
            /\ UNCHANGED <<inflight, usedRt, sends>>
       ELSE IF held /\ refreshable
       THEN /\ req' = [req EXCEPT ![k].phase = "waiting", ![k].again = TRUE]
            /\ inflight' = 1
            /\ usedRt' = rt
            /\ UNCHANGED sends
       ELSE /\ req' = [req EXCEPT ![k].phase = "needs_sign_in"]
            /\ UNCHANGED <<inflight, usedRt, sends>>
    /\ UNCHANGED <<gen, held, refreshable, rt, valid, serverRt, deadRt>>


Release(next) ==
    [k \in Keys |-> IF req[k].phase = "waiting" THEN [req[k] EXCEPT !.phase = next, !.g = gen + 1] ELSE req[k]]

Released(next) ==
    [k \in Keys |-> IF req[k].phase = "waiting" THEN sends[k] + 1 ELSE sends[k]]


Forget(k) ==
    /\ req[k].phase \in {"sent", "waiting"}
    /\ req' = [req EXCEPT ![k].phase = "cancelled"]
    /\ UNCHANGED <<gen, held, refreshable, rt, inflight, valid, serverRt, deadRt, usedRt, sends, rejectedG>>




RefreshOk(rotate) ==
    /\ inflight > 0
    /\ gen < MaxGen
    /\ gen' = gen + 1
    /\ held' = TRUE
    /\ valid' = valid \cup {gen + 1}
    /\ serverRt' = IF rotate THEN gen + 1 ELSE serverRt
    /\ rt' = IF rotate THEN gen + 1 ELSE rt
    /\ inflight' = 0
    /\ req' = Release("sent")
    /\ sends' = Released("sent")
    /\ UNCHANGED <<refreshable, deadRt, usedRt, rejectedG>>




RefreshRefused ==
    /\ inflight > 0
    /\ deadRt' = deadRt \cup {usedRt}
    /\ held' = FALSE
    /\ refreshable' = FALSE
    /\ inflight' = 0
    /\ req' = [k \in Keys |-> IF req[k].phase = "waiting" THEN [req[k] EXCEPT !.phase = "needs_sign_in"] ELSE req[k]]
    /\ UNCHANGED <<gen, rt, valid, serverRt, usedRt, sends, rejectedG>>



RefreshFailed ==
    /\ inflight > 0
    /\ inflight' = 0
    /\ req' = [k \in Keys |-> IF req[k].phase = "waiting" THEN [req[k] EXCEPT !.phase = "failed"] ELSE req[k]]
    /\ UNCHANGED <<gen, held, refreshable, rt, valid, serverRt, deadRt, usedRt, sends, rejectedG>>




Expire(g) ==
    /\ g \in valid
    /\ valid' = valid \ {g}
    /\ UNCHANGED <<gen, held, refreshable, rt, inflight, req, serverRt, deadRt, usedRt, sends, rejectedG>>




SignedIn(withRefresh) ==
    /\ gen < MaxGen
    /\ gen' = gen + 1
    /\ held' = TRUE
    /\ refreshable' = withRefresh
    /\ rt' = gen + 1
    /\ serverRt' = gen + 1
    /\ valid' = valid \cup {gen + 1}
    /\ inflight' = 0
    /\ req' = Release("sent")
    /\ sends' = Released("sent")
    /\ UNCHANGED <<deadRt, usedRt, rejectedG>>


SignOut ==
    /\ held' = FALSE
    /\ refreshable' = FALSE
    /\ inflight' = 0
    /\ req' = [k \in Keys |-> IF req[k].phase = "waiting" THEN [req[k] EXCEPT !.phase = "needs_sign_in"] ELSE req[k]]
    /\ UNCHANGED <<gen, rt, valid, serverRt, deadRt, usedRt, sends, rejectedG>>

Answer(k) == Accept(k) \/ Reject(k)
Refreshed == (\E r \in BOOLEAN : RefreshOk(r)) \/ RefreshRefused \/ RefreshFailed

Next ==
    \/ \E k \in Keys, e \in BOOLEAN : Send(k, e)
    \/ \E k \in Keys : Answer(k) \/ Forget(k)
    \/ Refreshed
    \/ \E g \in valid : Expire(g)
    \/ \E r \in BOOLEAN : SignedIn(r)
    \/ SignOut



Fairness ==
    /\ \A k \in Keys : WF_vars(Answer(k))
    /\ WF_vars(Refreshed)

Spec == Init /\ [][Next]_vars /\ Fairness



TypeOK ==
    /\ gen \in 0..MaxGen
    /\ held \in BOOLEAN /\ refreshable \in BOOLEAN
    /\ inflight \in Nat
    /\ \A k \in Keys : req[k].phase \in Phases /\ req[k].g \in 0..MaxGen /\ req[k].again \in BOOLEAN
    /\ valid \subseteq 0..MaxGen
    /\ deadRt \subseteq 0..MaxGen


SingleFlightRefresh == inflight <= 1



RefreshUsesLatest == inflight > 0 => usedRt = serverRt



NoDeadRefresh == inflight > 0 => usedRt \notin deadRt



SendsBound == \A k \in Keys : sends[k] <= 2
NewerOnResend == \A k \in Keys : (req[k].phase = "sent" /\ req[k].again) => req[k].g > rejectedG[k]


WaitingHasRefresh == (\E k \in Keys : req[k].phase = "waiting") => inflight > 0


EveryRequestEnds == \A k \in Keys : req[k].phase \in {"sent", "waiting"} ~> req[k].phase \in {"done", "needs_sign_in", "failed", "cancelled"}
====
