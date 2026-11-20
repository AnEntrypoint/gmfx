------------------------ MODULE PromptImagesTrace ------------------------





















EXTENDS PromptImages, TraceData, TLC

VARIABLE l

traceVars == <<vars, l>>

ASSUME TLCSet(1, 0)

Hidden ==
    \/ \E s \in Sessions, a \in SUBSET Digests : Begin(s, a)
    \/ \E a \in SUBSET Digests : Import(a)
    \/ \E d \in Digests : Save(d) \/ SaveFails(d)
    \/ Finish \/ Crash \/ Restart

Form(e, d) == IF d \in e.refs THEN "ref" ELSE IF d \in e.inline THEN "inline" ELSE "none"

Observed(e) ==
    \/ /\ e.event = "Request"
       /\ Request
       /\ requests'[Len(requests')] = [s |-> e.s, asked |-> e.asked, sent |-> e.sent, noted |-> e.noted]
    \/ /\ e.event = "Write"
       /\ Write
       /\ log'[e.s][Len(log'[e.s])] =
            [asked |-> e.refs \cup e.inline,
             images |-> [d \in Digests |-> Form(e, d)],
             listed |-> e.listed]
    \/ /\ e.event = "Blobs"
       /\ blobs[e.s] = e.blobs
       /\ UNCHANGED vars

TraceInit == Init /\ l = 1

TraceNext ==
    /\ l <= Len(Trace)
    /\ \/ Hidden /\ UNCHANGED l
       \/ Observed(Trace[l]) /\ l' = l + 1


Progress ==
    IF l > TLCGet(1)
    THEN TLCSet(1, l) /\ PrintT(<<"matched_lines", l - 1>>)
    ELSE TRUE

TraceIncomplete == l <= Len(Trace)
=============================================================================
