---- MODULE UrlRetryTrace ----

















EXTENDS UrlRetry, TraceObs, Sequences

VARIABLES i, bad

Viol ==
    (IF CountsOwnCompletions THEN {} ELSE {"CountsOwnCompletions"}) \cup
    (IF SeenWhenDone THEN {} ELSE {"SeenWhenDone"}) \cup
    (IF SignalTruth THEN {} ELSE {"SignalTruth"}) \cup
    (IF RetryOnlyAfterProof THEN {} ELSE {"RetryOnlyAfterProof"}) \cup
    (IF EndsByUserOrServer THEN {} ELSE {"EndsByUserOrServer"})

Step(rec) ==
    CASE rec.event = "call" -> calls = rec.data.n /\ UNCHANGED vars
      [] rec.event = "required" -> ServerRequires
      [] rec.event = "consent_shown" -> phase = "consent" /\ UNCHANGED vars
      [] rec.event = "accept" -> UserAccepts
      [] rec.event = "waiting_shown" -> phase = "waiting" /\ UNCHANGED vars
      [] rec.event = "complete" ->
            \E s \in SlotIds : ownCall[s] = calls /\ ownUrl[s] = rec.data.url /\ ServerCompletes(s)
      [] rec.event = "ignored" -> UNCHANGED vars
      [] rec.event = "retry" -> UserRetries
      [] rec.event = "cancel" -> UserCancels
      [] rec.event = "result" -> ServerAnswers
      [] rec.event = "end" -> phase = "done" /\ ended = rec.data.how /\ UNCHANGED vars
      [] OTHER -> FALSE


Hidden == AutoRetry

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
