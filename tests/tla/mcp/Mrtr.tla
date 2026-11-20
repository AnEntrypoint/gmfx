---- MODULE Mrtr ----


















EXTENDS Naturals

CONSTANTS
    MaxRequests,
    MaxKeys

ASSUME MaxRequests \in Nat \ {0} /\ MaxKeys \in Nat \ {0}

Outcomes == {"none", "result", "failure", "lost", "http_failure", "cancelled",
             "rounds_exceeded", "unsupported_input", "malformed"}

VARIABLES
    phase,
    round,
    lastState,
    requested,
    supported,
    sentState,
    responded,
    outcome,

    brought,
    sentDone

vars == <<phase, round, lastState, requested, supported, sentState, responded, outcome, brought, sentDone>>

Init ==
    /\ phase = "idle"
    /\ round = 0
    /\ lastState = 0
    /\ requested = 0
    /\ supported = TRUE
    /\ sentState = 0
    /\ responded = 0
    /\ outcome = "none"
    /\ brought = 0
    /\ sentDone = FALSE


Send ==
    /\ round' = round + 1
    /\ sentState' = lastState
    /\ sentDone' = (sentDone \/ phase = "done")

Start ==
    /\ phase = "idle"
    /\ phase' = "sent"
    /\ responded' = 0
    /\ Send
    /\ UNCHANGED <<lastState, requested, supported, outcome, brought>>


Ended(o) ==
    /\ phase = "sent"
    /\ phase' = "done"
    /\ outcome' = o
    /\ UNCHANGED <<round, lastState, requested, supported, sentState, responded, brought, sentDone>>

Malformed == Ended("malformed")

InputRequired(n, st, sup) ==
    /\ phase = "sent"
    /\ n > 0 \/ st
    /\ requested' = n
    /\ supported' = sup
    /\ lastState' = IF st THEN round ELSE 0
    /\ brought' = IF st THEN round ELSE 0
    /\ IF round = MaxRequests
       THEN phase' = "done" /\ outcome' = "rounds_exceeded"
       ELSE IF n > 0 /\ ~sup
       THEN phase' = "done" /\ outcome' = "unsupported_input"
       ELSE IF n > 0
       THEN phase' = "asking" /\ UNCHANGED outcome
       ELSE phase' = "backoff" /\ UNCHANGED outcome
    /\ UNCHANGED <<round, sentState, responded, sentDone>>


Provide ==
    /\ phase = "asking"
    /\ phase' = "sent"
    /\ responded' = requested
    /\ Send
    /\ UNCHANGED <<lastState, requested, supported, outcome, brought>>


BackoffDone ==
    /\ phase = "backoff"
    /\ phase' = "sent"
    /\ responded' = 0
    /\ Send
    /\ UNCHANGED <<lastState, requested, supported, outcome, brought>>


Cancel ==
    /\ phase \in {"sent", "asking", "backoff"}
    /\ phase' = "done"
    /\ outcome' = "cancelled"
    /\ UNCHANGED <<round, lastState, requested, supported, sentState, responded, brought, sentDone>>

Server ==
    \/ \E o \in {"result", "failure", "lost", "http_failure"} : Ended(o)
    \/ Malformed
    \/ \E n \in 0..MaxKeys, st \in BOOLEAN, sup \in BOOLEAN : InputRequired(n, st, sup)

Next == Start \/ Provide \/ BackoffDone \/ Cancel \/ Server




HostAnswers == Provide \/ (phase = "asking" /\ Cancel)

Fairness ==
    /\ WF_vars(Start)
    /\ WF_vars(BackoffDone)
    /\ WF_vars(HostAnswers)
    /\ WF_vars(Server)

Spec == Init /\ [][Next]_vars /\ Fairness

---------------------------------------------------------------------------


TypeOK ==
    /\ phase \in {"idle", "sent", "asking", "backoff", "done"}
    /\ round \in 0..(MaxRequests + 1)
    /\ lastState \in 0..MaxRequests
    /\ requested \in 0..MaxKeys
    /\ supported \in BOOLEAN
    /\ sentState \in 0..MaxRequests
    /\ responded \in 0..MaxKeys
    /\ outcome \in Outcomes



StateEchoExact == phase = "sent" => sentState = brought



BackoffNeedsState == phase = "backoff" => brought # 0


ResponsesExact == phase = "sent" => responded = requested


NoAskUnsupported == phase = "asking" => supported


RoundCap == round <= MaxRequests

NothingAfterEnd == ~sentDone

EveryChainEnds == (phase # "idle") ~> (phase = "done")
====
