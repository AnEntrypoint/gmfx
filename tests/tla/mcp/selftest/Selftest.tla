---- MODULE Selftest ----




EXTENDS Naturals

CONSTANT AllowLateDelivery

VARIABLES status, outcomes

vars == <<status, outcomes>>

Init ==
    /\ status = "pending"
    /\ outcomes = 0

ResponseReceived ==
    /\ \/ status = "pending"
       \/ AllowLateDelivery /\ status = "cancelled"
    /\ status' = "done"
    /\ outcomes' = outcomes + 1

CancelRequested ==
    /\ status = "pending"
    /\ status' = "cancelled"
    /\ outcomes' = outcomes + 1

Next == ResponseReceived \/ CancelRequested \/ UNCHANGED vars

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ status \in {"pending", "done", "cancelled"}
    /\ outcomes \in 0..2

AtMostOneOutcome == outcomes <= 1
====
