---- MODULE SelftestTrace ----




EXTENDS Selftest, TraceObs, Naturals, Sequences

VARIABLE i

TraceInit ==
    /\ Init
    /\ i = 0

TraceNext ==
    /\ i < Len(ObsTrace)
    /\ LET rec == ObsTrace[i + 1] IN
         /\ status = rec.from
         /\ \/ rec.event = "response_received" /\ ResponseReceived
            \/ rec.event = "cancel_requested" /\ CancelRequested
         /\ status' = rec.to
         /\ "outcomes" \in DOMAIN rec.data
         /\ outcomes' = rec.data.outcomes
    /\ i' = i + 1


NotDone == i < Len(ObsTrace)
====
