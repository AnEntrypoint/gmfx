---------------------------- MODULE PromptImages ----------------------------


















EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS Digests, MaxRequests, MaxItems


Symmetry == Permutations(Digests)

Sessions == {"source", "fork"}
Forms == {"ref", "inline"}

Item == [asked : SUBSET Digests, images : [Digests -> Forms \cup {"none"}],
         listed : SUBSET Digests]

VARIABLES
    up,
    forked,
    blobs,
    log,
    pending,
    turn,
    requests

vars == <<up, forked, blobs, log, pending, turn, requests>>




NoTurn == [phase |-> "none", s |-> "source", asked |-> {},
           form |-> [d \in Digests |-> "none"],
           requested |-> FALSE, written |-> FALSE]

TypeOK ==
    /\ up \in BOOLEAN /\ forked \in BOOLEAN
    /\ blobs \in [Sessions -> SUBSET Digests]
    /\ \A s \in Sessions : log[s] \in Seq(Item)
    /\ pending \in [Sessions -> SUBSET Digests]
    /\ turn.phase \in {"none", "open"}
    /\ turn.s \in Sessions /\ turn.asked \subseteq Digests
    /\ turn.form \in [Digests -> Forms \cup {"none", "unsaved"}]
    /\ turn.requested \in BOOLEAN /\ turn.written \in BOOLEAN

Init ==
    /\ up = TRUE /\ forked = FALSE
    /\ blobs = [s \in Sessions |-> {}]
    /\ log = [s \in Sessions |-> <<>>]
    /\ pending = [s \in Sessions |-> {}]
    /\ turn = NoTurn
    /\ requests = <<>>

Open(s) == s = "source" \/ forked


Earlier(s, f) == {d \in Digests : \E k \in 1..Len(log[s]) : log[s][k].images[d] = f}


Begin(s, asked) ==
    /\ up /\ Open(s) /\ turn.phase = "none" /\ asked # {}
    /\ Len(log[s]) < MaxItems /\ Len(requests) < MaxRequests
    /\ turn' = [phase |-> "open", s |-> s, asked |-> asked,
                form |-> [d \in Digests |-> IF d \in asked THEN "unsaved" ELSE "none"],
                requested |-> FALSE, written |-> FALSE]
    /\ UNCHANGED <<up, forked, blobs, log, pending, requests>>




Import(asked) ==
    /\ up /\ ~forked /\ requests = <<>> /\ turn.phase = "none" /\ asked # {}
    /\ Len(log["source"]) < MaxItems
    /\ turn' = [phase |-> "open", s |-> "source", asked |-> asked,
                form |-> [d \in Digests |-> IF d \in asked THEN "unsaved" ELSE "none"],
                requested |-> TRUE, written |-> FALSE]
    /\ UNCHANGED <<up, forked, blobs, log, pending, requests>>


Saved == \A d \in turn.asked : turn.form[d] # "unsaved"



Save(d) ==
    /\ up /\ turn.phase = "open" /\ turn.form[d] = "unsaved"
    /\ blobs' = [blobs EXCEPT ![turn.s] = @ \cup {d}]
    /\ pending' = [pending EXCEPT ![turn.s] = @ \cup {d}]
    /\ turn' = [turn EXCEPT !.form[d] = "ref"]
    /\ UNCHANGED <<up, forked, log, requests>>


SaveFails(d) ==
    /\ up /\ turn.phase = "open" /\ turn.form[d] = "unsaved"
    /\ turn' = [turn EXCEPT !.form[d] = "inline"]
    /\ UNCHANGED <<up, forked, blobs, log, pending, requests>>



Request ==
    /\ up /\ turn.phase = "open" /\ ~turn.requested
    /\ Saved
    /\ requests' = Append(requests,
         [s |-> turn.s,
          asked |-> turn.asked,
          sent |-> {d \in turn.asked : turn.form[d] \in Forms}
                   \cup Earlier(turn.s, "ref") \cup Earlier(turn.s, "inline"),
          noted |-> {d \in turn.asked : turn.form[d] = "ref"} \cup Earlier(turn.s, "ref")])
    /\ turn' = [turn EXCEPT !.requested = TRUE]
    /\ UNCHANGED <<up, forked, blobs, log, pending>>



Write ==
    /\ up /\ turn.phase = "open" /\ ~turn.written
    /\ Saved
    /\ log' = [log EXCEPT ![turn.s] = Append(@,
         [asked |-> turn.asked,
          images |-> [d \in Digests |-> IF d \in turn.asked THEN turn.form[d] ELSE "none"],
          listed |-> pending[turn.s]])]
    /\ pending' = [pending EXCEPT ![turn.s] = {}]
    /\ turn' = [turn EXCEPT !.written = TRUE]
    /\ UNCHANGED <<up, forked, blobs, requests>>


Finish ==
    /\ up /\ turn.phase = "open" /\ turn.requested /\ turn.written
    /\ turn' = NoTurn
    /\ UNCHANGED <<up, forked, blobs, log, pending, requests>>



Crash ==
    /\ up /\ up' = FALSE
    /\ turn' = NoTurn /\ pending' = [s \in Sessions |-> {}]
    /\ UNCHANGED <<forked, blobs, log, requests>>

Restart == /\ ~up /\ up' = TRUE /\ UNCHANGED <<forked, blobs, log, pending, turn, requests>>



Fork ==
    /\ up /\ ~forked /\ turn.phase = "none" /\ Len(log["source"]) > 0
    /\ forked' = TRUE
    /\ log' = [log EXCEPT !["fork"] = log["source"]]
    /\ blobs' = [blobs EXCEPT !["fork"] =
         UNION {log["source"][k].listed : k \in 1..Len(log["source"])}]
    /\ UNCHANGED <<up, pending, turn, requests>>

Next ==
    \/ \E s \in Sessions, a \in SUBSET Digests : Begin(s, a)
    \/ \E a \in SUBSET Digests : Import(a)
    \/ \E d \in Digests : Save(d) \/ SaveFails(d)
    \/ Request \/ Write \/ Finish \/ Crash \/ Restart \/ Fork

Spec == Init /\ [][Next]_vars



NoteNamesBlob == \A k \in 1..Len(requests) : requests[k].noted \subseteq blobs[requests[k].s]



RefHasBlob ==
    \A s \in Sessions : \A k \in 1..Len(log[s]) : \A d \in Digests :
        log[s][k].images[d] = "ref" => d \in blobs[s]


ItemKeepsImages ==
    \A s \in Sessions : \A k \in 1..Len(log[s]) :
        {d \in Digests : log[s][k].images[d] \in Forms} = log[s][k].asked


RequestSendsAll == \A k \in 1..Len(requests) : requests[k].asked \subseteq requests[k].sent

=============================================================================
