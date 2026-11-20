---- MODULE MrtrTrace ----














EXTENDS Mrtr, TraceObs, Integers, Sequences

VARIABLE i

Step(r) ==
    CASE r.event = "start" -> Start
      [] r.event = "ended" -> Ended(r.data.outcome)
      [] r.event = "malformed" -> Malformed
      [] r.event = "input_required" -> InputRequired(r.data.requested, r.data.last_state # 0, r.data.supported)
      [] r.event = "provide" -> Provide
      [] r.event = "backoff_done" -> BackoffDone
      [] r.event = "cancel" -> Cancel
      [] OTHER -> FALSE

Matches(r) ==
    /\ phase' = r.to
    /\ round' = r.data.round
    /\ lastState' = r.data.last_state
    /\ requested' = r.data.requested
    /\ supported' = r.data.supported
    /\ sentState' = r.data.sent_state
    /\ responded' = r.data.responded
    /\ outcome' = r.data.outcome

TraceInit ==
    /\ Init
    /\ i = 0

TraceNext ==
    /\ i < Len(ObsTrace)
    /\ LET r == ObsTrace[i + 1]
       IN /\ phase = r.from
          /\ IF r.data.ignored THEN ~ENABLED Step(r) /\ UNCHANGED vars ELSE Step(r)
          /\ Matches(r)
    /\ i' = i + 1


NotDone == i < Len(ObsTrace)
====
