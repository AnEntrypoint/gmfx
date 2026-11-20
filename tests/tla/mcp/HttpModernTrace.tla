---- MODULE HttpModernTrace ----














EXTENDS HttpModern, TraceObs, Integers, Sequences

VARIABLE i

Step(r) ==
    CASE r.event = "send" -> Send
      [] r.event = "answer" -> Answer(r.data.answer)
      [] r.event = "http_failure" -> HttpFailure
      [] r.event = "stream_broken" -> StreamBroken
      [] r.event = "too_large" -> TooLarge
      [] r.event = "relisted" -> Relisted(r.data.ok)
      [] r.event = "cancel" -> Cancel
      [] OTHER -> FALSE

Emits(r, e) == \E k \in DOMAIN r.effects : r.effects[k] = e

Matches(r) ==
    /\ phase' = r.to
    /\ kind' = r.data.kind
    /\ attempts' = r.data.attempts
    /\ headerRetries' = r.data.header_retries
    /\ maybeRan' = r.data.maybe_ran
    /\ Emits(r, "close") = (closed' /\ ~closed)

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
