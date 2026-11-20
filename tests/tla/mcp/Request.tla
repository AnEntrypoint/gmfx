---- MODULE Request ----

















EXTENDS Naturals, FiniteSets

CONSTANTS Ids, InitIds, ListenIds, MaxProgress

ASSUME InitIds \subseteq Ids /\ ListenIds \subseteq Ids \ InitIds /\ MaxProgress \in Nat

Status == {"unused", "inflight", "done"}
Outcome == {"none", "result", "error", "cancelled", "timed_out", "lost", "ended"}
PeerKind == {"result", "error"}

VARIABLES
    req,
    outcome,
    delivered,
    cancelSent,
    progress,
    everDone,
    peerAnswered,
    progressSeen

vars == <<req, outcome, delivered, cancelSent, progress, everDone, peerAnswered, progressSeen>>

Init ==
    /\ req = [id \in Ids |-> "unused"]
    /\ outcome = [id \in Ids |-> "none"]
    /\ delivered = [id \in Ids |-> 0]
    /\ cancelSent = [id \in Ids |-> FALSE]
    /\ progress = [id \in Ids |-> 0]
    /\ everDone = [id \in Ids |-> FALSE]
    /\ peerAnswered = [id \in Ids |-> FALSE]
    /\ progressSeen = {}


Finish(id, o) ==
    /\ req' = [req EXCEPT ![id] = "done"]
    /\ outcome' = [outcome EXCEPT ![id] = o]
    /\ delivered' = [delivered EXCEPT ![id] = @ + 1]
    /\ everDone' = [everDone EXCEPT ![id] = TRUE]


Send(id) ==
    /\ req[id] = "unused"
    /\ req' = [req EXCEPT ![id] = "inflight"]
    /\ UNCHANGED <<outcome, delivered, cancelSent, progress, everDone, peerAnswered, progressSeen>>

Accept(id, kind) ==
    /\ Finish(id, kind)
    /\ peerAnswered' = [peerAnswered EXCEPT ![id] = TRUE]
    /\ UNCHANGED <<cancelSent, progress, progressSeen>>



ResponseReceived(id, kind) ==
    IF req[id] = "inflight" THEN Accept(id, kind) ELSE UNCHANGED vars


CancelRequested(id) ==
    /\ req[id] = "inflight"
    /\ id \notin InitIds
    /\ Finish(id, "cancelled")
    /\ cancelSent' = [cancelSent EXCEPT ![id] = TRUE]
    /\ UNCHANGED <<progress, peerAnswered, progressSeen>>




TimedOut(id) ==
    /\ req[id] = "inflight"
    /\ id \notin ListenIds
    /\ Finish(id, "timed_out")
    /\ cancelSent' = [cancelSent EXCEPT ![id] = ~(id \in InitIds)]
    /\ UNCHANGED <<progress, peerAnswered, progressSeen>>



TransportLost(id) ==
    /\ req[id] = "inflight"
    /\ Finish(id, "lost")
    /\ UNCHANGED <<cancelSent, progress, peerAnswered, progressSeen>>



ProgressReceived(id, p) ==
    IF req[id] = "inflight" /\ p > progress[id]
    THEN /\ progress' = [progress EXCEPT ![id] = p]
         /\ progressSeen' = progressSeen \cup {<<id, req[id]>>}
         /\ UNCHANGED <<req, outcome, delivered, cancelSent, everDone, peerAnswered>>
    ELSE UNCHANGED vars




ServerCancelReceived(id) ==
    IF id \in ListenIds /\ req[id] = "inflight"
    THEN /\ Finish(id, "ended")
         /\ peerAnswered' = [peerAnswered EXCEPT ![id] = TRUE]
         /\ UNCHANGED <<cancelSent, progress, progressSeen>>
    ELSE UNCHANGED vars

Next ==
    \E id \in Ids:
        \/ Send(id)
        \/ \E kind \in PeerKind: ResponseReceived(id, kind)
        \/ CancelRequested(id)
        \/ TimedOut(id)
        \/ TransportLost(id)
        \/ \E p \in 1..MaxProgress: ProgressReceived(id, p)
        \/ ServerCancelReceived(id)

Spec == Init /\ [][Next]_vars /\ \A id \in Ids: WF_vars(TimedOut(id))

TypeOK ==
    /\ req \in [Ids -> Status]
    /\ outcome \in [Ids -> Outcome]
    /\ delivered \in [Ids -> 0..2]
    /\ cancelSent \in [Ids -> BOOLEAN]
    /\ progress \in [Ids -> 0..MaxProgress]
    /\ everDone \in [Ids -> BOOLEAN]
    /\ peerAnswered \in [Ids -> BOOLEAN]
    /\ progressSeen \subseteq (Ids \X Status)


IdsNeverReused == \A id \in Ids: everDone[id] => req[id] = "done"


AtMostOneOutcome == \A id \in Ids: delivered[id] <= 1


OutcomeIffDone == \A id \in Ids: (req[id] = "done") = (delivered[id] = 1 /\ outcome[id] # "none")


PeerOutcomesFromPeer == \A id \in Ids: outcome[id] \in PeerKind \cup {"ended"} => peerAnswered[id]


ListenNeverTimesOut == \A id \in ListenIds: outcome[id] # "timed_out"


EndedOnlyListen == \A id \in Ids: outcome[id] = "ended" => id \in ListenIds


CancelledByClientOnly == \A id \in Ids: outcome[id] = "cancelled" => cancelSent[id]


CancelValid == \A id \in Ids: cancelSent[id] => outcome[id] \in {"cancelled", "timed_out"}


NeverCancelInitialize == \A id \in InitIds: ~cancelSent[id]


ProgressScoped == \A x \in progressSeen: x[2] = "inflight"


EveryRequestEnds == \A id \in Ids \ ListenIds: req[id] = "inflight" ~> req[id] = "done"
====
