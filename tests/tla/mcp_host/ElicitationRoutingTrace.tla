---- MODULE ElicitationRoutingTrace ----














EXTENDS ElicitationRouting, TraceObs, Sequences

VARIABLES i, bad

Viol ==
    (IF AnsweredOnce THEN {} ELSE {"AnsweredOnce"}) \cup
    (IF DismissedNeverShown THEN {} ELSE {"DismissedNeverShown"}) \cup
    (IF AnswerReachesSeenQuestion THEN {} ELSE {"AnswerReachesSeenQuestion"})

Step(rec) ==
    CASE rec.event = "ask" -> Ask /\ nextQ = rec.data.q
      [] rec.event = "shown" -> Take /\ offered = rec.data.q
      [] rec.event = "answer" -> UserAnswers /\ asking = rec.data.q
      [] rec.event = "delivered" -> Deliver /\ answeredBy'[rec.data.target] = rec.data.from /\ answeredBy[rec.data.target] = None
      [] rec.event = "fx_dismissed" -> answeredBy[rec.data.q] = rec.data.q /\ dismissed[rec.data.q] /\ UNCHANGED vars
      [] rec.event = "withdraw" -> Withdraw(rec.data.q)
      [] rec.event = "call_end" -> CallEnds
      [] OTHER -> FALSE



Hidden == Deliver /\ answeredBy' = answeredBy

TraceInit == Init /\ i = 0 /\ bad = Viol

TraceNext ==
    \/ /\ i < Len(ObsTrace)
       /\ Step(ObsTrace[i + 1])
       /\ i' = i + 1
       /\ bad' = bad \cup Viol'
    \/ /\ Hidden
       /\ UNCHANGED i
       /\ bad' = bad \cup Viol'

NotDone == i < Len(ObsTrace)
NotDoneClean == i < Len(ObsTrace) \/ bad # {}
NotDoneDirty == i < Len(ObsTrace) \/ bad = {}
====
