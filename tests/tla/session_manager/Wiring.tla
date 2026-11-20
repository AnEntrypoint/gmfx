------------------------------ MODULE Wiring ------------------------------



















CONSTANT Sessions

Ends == {"none", "commit", "interrupt"}

VARIABLES
    up,
    cur,
    turnOpen,
    lastEnd,
    linked,
    child,
    childOf,
    next,
    made,
    forkOf

vars == <<up, cur, turnOpen, lastEnd, linked, child, childOf, next, made, forkOf>>

TypeOK ==
    /\ up \in BOOLEAN
    /\ cur \in Sessions \cup {"none"}
    /\ turnOpen \in [Sessions -> BOOLEAN]
    /\ lastEnd \in [Sessions -> Ends]
    /\ linked \in [Sessions -> Ends]
    /\ child \in {"none", "running"}
    /\ childOf \in Sessions \cup {"none"}
    /\ next \in Sessions \cup {"none"}
    /\ made \in [Sessions -> BOOLEAN]
    /\ forkOf \in [Sessions -> Sessions \cup {"none"}]

Init ==
    /\ up = FALSE
    /\ cur = "none"
    /\ turnOpen = [s \in Sessions |-> FALSE]
    /\ lastEnd = [s \in Sessions |-> "none"]
    /\ linked = [s \in Sessions |-> "none"]
    /\ child = "none"
    /\ childOf = "none"
    /\ next = "none"
    /\ made = [s \in Sessions |-> FALSE]
    /\ forkOf = [s \in Sessions |-> "none"]

Active == up /\ cur # "none"


Start ==
    /\ ~up
    /\ up' = TRUE
    /\ UNCHANGED <<cur, turnOpen, lastEnd, linked, child, childOf, next, made, forkOf>>



Open(s) ==
    /\ up
    /\ next = "none"
    /\ s # cur
    /\ IF cur = "none" THEN cur' = s /\ next' = "none" ELSE cur' = cur /\ next' = s
    /\ turnOpen' = [turnOpen EXCEPT ![s] = FALSE]
    /\ lastEnd' = IF turnOpen[s] THEN [lastEnd EXCEPT ![s] = "interrupt"] ELSE lastEnd
    /\ made' = [made EXCEPT ![s] = TRUE]
    /\ UNCHANGED <<up, linked, child, childOf, forkOf>>


Idle == Active /\ next = "none"

BeginTurn ==
    /\ Idle
    /\ ~turnOpen[cur]
    /\ turnOpen' = [turnOpen EXCEPT ![cur] = TRUE]
    /\ linked' = [linked EXCEPT ![cur] = "none"]
    /\ UNCHANGED <<up, cur, lastEnd, child, childOf, next, made, forkOf>>



Continue ==
    /\ Idle
    /\ ~turnOpen[cur]
    /\ lastEnd[cur] = "interrupt"
    /\ turnOpen' = [turnOpen EXCEPT ![cur] = TRUE]
    /\ linked' = [linked EXCEPT ![cur] = lastEnd[cur]]
    /\ UNCHANGED <<up, cur, lastEnd, child, childOf, next, made, forkOf>>


EndTurn(e) ==
    /\ Active
    /\ turnOpen[cur]
    /\ turnOpen' = [turnOpen EXCEPT ![cur] = FALSE]
    /\ lastEnd' = [lastEnd EXCEPT ![cur] = e]
    /\ UNCHANGED <<up, cur, linked, child, childOf, next, made, forkOf>>


Spawn ==
    /\ Idle
    /\ turnOpen[cur]
    /\ child = "none"
    /\ child' = "running"
    /\ childOf' = cur
    /\ UNCHANGED <<up, cur, turnOpen, lastEnd, linked, next, made, forkOf>>



ChildDone ==
    /\ up
    /\ child = "running"
    /\ cur = childOf
    /\ child' = "none"
    /\ childOf' = "none"
    /\ UNCHANGED <<up, cur, turnOpen, lastEnd, linked, next, made, forkOf>>





Close(s) ==
    /\ up
    /\ s \in {cur, next} \ {"none"}
    /\ child = "none"
    /\ cur' = IF s = cur THEN next ELSE cur
    /\ next' = "none"
    /\ turnOpen' = [turnOpen EXCEPT ![s] = FALSE]
    /\ lastEnd' = IF turnOpen[s] THEN [lastEnd EXCEPT ![s] = "interrupt"] ELSE lastEnd
    /\ UNCHANGED <<up, linked, child, childOf, made, forkOf>>






Fork(f) ==
    /\ Idle
    /\ child = "none"
    /\ f \notin {cur, next}
    /\ ~made[f]
    /\ ~turnOpen[cur]
    /\ next' = f
    /\ made' = [made EXCEPT ![f] = TRUE]
    /\ forkOf' = [forkOf EXCEPT ![f] = cur]
    /\ \E e \in Ends : lastEnd' = [lastEnd EXCEPT ![f] = e]
    /\ UNCHANGED <<up, cur, turnOpen, linked, child, childOf>>

Exit ==
    /\ up
    /\ cur = "none"
    /\ next = "none"
    /\ child = "none"
    /\ up' = FALSE
    /\ UNCHANGED <<cur, turnOpen, lastEnd, linked, child, childOf, next, made, forkOf>>


Crash ==
    /\ up
    /\ up' = FALSE
    /\ cur' = "none"
    /\ next' = "none"
    /\ child' = "none"
    /\ childOf' = "none"
    /\ UNCHANGED <<turnOpen, lastEnd, linked, made, forkOf>>

Next ==
    \/ Start
    \/ \E s \in Sessions : Open(s) \/ Close(s)
    \/ BeginTurn \/ Continue
    \/ \E e \in {"commit", "interrupt"} : EndTurn(e)
    \/ Spawn \/ ChildDone
    \/ \E f \in Sessions : Fork(f)
    \/ Exit \/ Crash

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------



ParentOutlivesChildren == child = "running" => (up /\ cur = childOf)


SwitchIsTwoSessions == next # "none" => (cur # "none" /\ cur # next)


ContinueLinksInterrupted == \A s \in Sessions : linked[s] \in {"none", "interrupt"}



ForkStep(f) == forkOf'[f] # forkOf[f]


ForkIsNewSession == [][\A f \in Sessions : ForkStep(f) => ~made[f]]_vars


ForkLeavesSource ==
    [][\A f \in Sessions : ForkStep(f) =>
         /\ turnOpen'[cur] = turnOpen[cur] /\ lastEnd'[cur] = lastEnd[cur]
         /\ linked'[cur] = linked[cur]]_vars


ForkBetweenTurns ==
    [][\A f \in Sessions : ForkStep(f) => (~turnOpen[cur] /\ child = "none")]_vars
=============================================================================
