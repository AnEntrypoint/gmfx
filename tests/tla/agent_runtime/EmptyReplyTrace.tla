--------------------------- MODULE EmptyReplyTrace ---------------------------















EXTENDS EmptyReply, EmptyReplyObserved

VARIABLE k
traceVars == <<vars, k>>

TraceInit == k = 1 /\ InitWith(Observed[1].limit)

Step ==
    /\ k <= Len(Observed)
    /\ Len(replies) < Len(Observed[k].replies)
    /\ Reply(Observed[k].replies[Len(replies) + 1])
    /\ UNCHANGED k

Matches(o) ==
    /\ phase = "done"
    /\ replies = o.replies
    /\ sent = o.sent
    /\ outcome = o.outcome

Advance ==
    /\ k <= Len(Observed)
    /\ Matches(Observed[k])
    /\ k' = k + 1
    /\ IF k + 1 <= Len(Observed) THEN Reset(Observed[k + 1].limit) ELSE UNCHANGED vars

TraceSpec == TraceInit /\ [][Step \/ Advance]_traceVars


NotAllMatched == k <= Len(Observed)
=============================================================================
