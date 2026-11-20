---- MODULE RequestTrace ----











EXTENDS Request, TraceObs, Naturals, Sequences

VARIABLE i

Recs == {ObsTrace[k] : k \in 1..Len(ObsTrace)}
Has(r, f) == f \in DOMAIN r.data

ObsIds == {r.data.id : r \in Recs}
ObsInitIds == {r.data.id : r \in {x \in Recs : Has(x, "kind") /\ x.data.kind = "initialize"}}
ObsListenIds == {r.data.id : r \in {x \in Recs : Has(x, "kind") /\ x.data.kind = "listen"}}
ObsProgress == {r.data.progress : r \in {x \in Recs : Has(x, "progress")}}
ObsMaxProgress == IF ObsProgress = {} THEN 0 ELSE CHOOSE m \in ObsProgress : \A q \in ObsProgress : q <= m

Step(r, id) ==
    \/ r.event = "send" /\ Send(id)
    \/ r.event = "response_received" /\ ResponseReceived(id, r.data.response)
    \/ r.event = "cancel_requested" /\ (CancelRequested(id) \/ (req[id] # "inflight" /\ UNCHANGED vars))
    \/ r.event = "timer_fired" /\ (TimedOut(id) \/ UNCHANGED vars)
    \/ r.event = "transport_lost" /\ (TransportLost(id) \/ (req[id] # "inflight" /\ UNCHANGED vars))


    \/ r.event = "progress_received" /\ ((\E p \in 1..MaxProgress : ProgressReceived(id, p)) \/ UNCHANGED vars)
    \/ r.event = "server_cancel_received" /\ ServerCancelReceived(id)

Matches(r, id) ==
    /\ req'[id] = r.to
    /\ Has(r, "outcome") => outcome'[id] = r.data.outcome
    /\ Has(r, "delivered") => delivered'[id] = r.data.delivered
    /\ Has(r, "cancel_sent") => cancelSent'[id] = r.data.cancel_sent
    /\ Has(r, "progress") => progress'[id] = r.data.progress

TraceInit ==
    /\ Init
    /\ i = 0

TraceNext ==
    /\ i < Len(ObsTrace)
    /\ LET r == ObsTrace[i + 1]
           id == r.data.id
       IN /\ id \in Ids
          /\ req[id] = r.from
          /\ Step(r, id)
          /\ Matches(r, id)
    /\ i' = i + 1


NotDone == i < Len(ObsTrace)
====
