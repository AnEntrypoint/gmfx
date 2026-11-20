---- MODULE HttpModern ----















EXTENDS Naturals

CONSTANTS
    MaxAttempts

ASSUME MaxAttempts \in Nat \ {0}

Terminal == {"done", "lost", "failed", "cancelled"}

VARIABLES
    kind,
    phase,
    attempts,
    headerRetries,
    currentId,
    nextId,
    outcome,
    maybeRan,
    closed,

    usedIds,
    reused,
    delivered,
    cancelNote

vars == <<kind, phase, attempts, headerRetries, currentId, nextId, outcome, maybeRan,
          closed, usedIds, reused, delivered, cancelNote>>

Init ==
    /\ kind \in {"call", "idempotent"}
    /\ phase = "idle"
    /\ attempts = 0
    /\ headerRetries = 0
    /\ currentId = 0
    /\ nextId = 1
    /\ outcome = "none"
    /\ maybeRan = FALSE
    /\ closed = FALSE
    /\ usedIds = {}
    /\ reused = FALSE
    /\ delivered = 0
    /\ cancelNote = FALSE


Post ==
    /\ phase' = "posted"
    /\ currentId' = nextId
    /\ nextId' = nextId + 1
    /\ reused' = (reused \/ currentId' \in usedIds)
    /\ usedIds' = usedIds \cup {currentId'}
    /\ closed' = FALSE

Deliver(o) ==
    /\ outcome' = o
    /\ delivered' = delivered + 1


Send ==
    /\ phase = "idle"
    /\ attempts' = 1
    /\ Post
    /\ UNCHANGED <<kind, headerRetries, outcome, maybeRan, delivered, cancelNote>>


Answer(a) ==
    /\ phase = "posted"
    /\ IF a = "mismatch" /\ kind = "call" /\ headerRetries = 0
          THEN /\ phase' = "relisting"
               /\ headerRetries' = 1
               /\ UNCHANGED <<outcome, delivered>>
          ELSE /\ phase' = "done"
               /\ Deliver(IF a = "result" THEN "result" ELSE "error")
               /\ UNCHANGED headerRetries
    /\ closed' = TRUE
    /\ UNCHANGED <<kind, attempts, currentId, nextId, maybeRan, usedIds, reused, cancelNote>>




HttpFailure ==
    /\ phase = "posted"
    /\ phase' = "failed"
    /\ Deliver("failed")
    /\ UNCHANGED <<kind, attempts, headerRetries, currentId, nextId, maybeRan, closed, usedIds, reused, cancelNote>>


StreamBroken ==
    /\ phase = "posted"
    /\ IF kind = "idempotent" /\ attempts < MaxAttempts
          THEN /\ attempts' = attempts + 1
               /\ Post
               /\ UNCHANGED <<outcome, maybeRan, delivered>>
          ELSE /\ phase' = "lost"
               /\ maybeRan' = (kind = "call")
               /\ Deliver("lost")
               /\ UNCHANGED <<attempts, currentId, nextId, closed, usedIds, reused>>
    /\ UNCHANGED <<kind, headerRetries, cancelNote>>



TooLarge ==
    /\ phase = "posted"
    /\ phase' = "lost"
    /\ maybeRan' = (kind = "call")
    /\ Deliver("lost")
    /\ UNCHANGED <<kind, attempts, headerRetries, currentId, nextId, closed, usedIds, reused, cancelNote>>


Relisted(ok) ==
    /\ phase = "relisting"
    /\ IF ok
          THEN /\ Post
               /\ UNCHANGED <<outcome, delivered>>
          ELSE /\ phase' = "done"
               /\ Deliver("error")
               /\ UNCHANGED <<currentId, nextId, usedIds, reused, closed>>
    /\ UNCHANGED <<kind, attempts, headerRetries, maybeRan, cancelNote>>


Cancel ==
    /\ phase \in {"posted", "relisting"}
    /\ phase' = "cancelled"
    /\ closed' = TRUE
    /\ outcome' = "cancelled"
    /\ delivered' = delivered + 1
    /\ UNCHANGED <<kind, attempts, headerRetries, currentId, nextId, maybeRan, usedIds, reused,
                   cancelNote>>

Environment ==
    \/ \E a \in {"result", "error", "mismatch"} : Answer(a)
    \/ HttpFailure
    \/ StreamBroken
    \/ TooLarge
    \/ \E ok \in BOOLEAN : Relisted(ok)

Next == Send \/ Environment \/ Cancel


Spec == Init /\ [][Next]_vars /\ WF_vars(Environment)

TypeOK ==
    /\ kind \in {"call", "idempotent"}
    /\ phase \in {"idle", "posted", "relisting"} \cup Terminal
    /\ attempts \in 0..MaxAttempts
    /\ headerRetries \in 0..1
    /\ maybeRan \in BOOLEAN
    /\ closed \in BOOLEAN


ReissueNewId == ~reused


AtMostOneOutcome == delivered <= 1


NoCallResent == kind = "call" => attempts <= 1


MaybeRanOnlyForLostCalls == maybeRan => (kind = "call" /\ phase = "lost")


CancelByClose == (phase = "cancelled" => closed) /\ ~cancelNote


AnsweredStreamClosed == phase \in {"done", "relisting"} => closed



TooLargeEnds == [][TooLarge => phase' = "lost"]_vars


EveryRequestEnds == phase \in {"posted", "relisting"} ~> phase \in Terminal
====
