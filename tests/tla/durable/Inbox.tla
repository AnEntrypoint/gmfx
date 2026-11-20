------------------------------- MODULE Inbox -------------------------------











EXTENDS Naturals, FiniteSets

CONSTANTS Inputs, MaxRequests, MaxCrashes

VARIABLES
    alive,
    submitted,
    acked,
    jAccepted,
    jWithdrawn,
    jPlaced,
    carried,
    nreq,
    memPending,
    answer,
    crashes

vars == <<alive, submitted, acked, jAccepted, jWithdrawn, jPlaced, carried,
          nreq, memPending, answer, crashes>>

Requests == 1..MaxRequests

TypeOK ==
    /\ alive \in BOOLEAN
    /\ submitted \subseteq Inputs
    /\ acked \subseteq Inputs
    /\ jAccepted \subseteq Inputs
    /\ jWithdrawn \subseteq Inputs
    /\ jPlaced \in [Inputs -> 0..MaxRequests]
    /\ carried \in [Requests -> SUBSET Inputs]
    /\ nreq \in 0..MaxRequests
    /\ memPending \subseteq Inputs
    /\ answer \in [Inputs -> {"none", "withdrawn", "already_placed"}]
    /\ crashes \in 0..MaxCrashes

Init ==
    /\ alive = TRUE
    /\ submitted = {}
    /\ acked = {}
    /\ jAccepted = {}
    /\ jWithdrawn = {}
    /\ jPlaced = [i \in Inputs |-> 0]
    /\ carried = [r \in Requests |-> {}]
    /\ nreq = 0
    /\ memPending = {}
    /\ answer = [i \in Inputs |-> "none"]
    /\ crashes = 0


Submit(i) ==
    /\ i \notin submitted
    /\ submitted' = submitted \cup {i}
    /\ UNCHANGED <<alive, acked, jAccepted, jWithdrawn, jPlaced, carried, nreq, memPending, answer, crashes>>


Accept(i) ==
    /\ alive
    /\ i \in submitted
    /\ i \notin jAccepted
    /\ jAccepted' = jAccepted \cup {i}
    /\ memPending' = memPending \cup {i}
    /\ UNCHANGED <<alive, submitted, acked, jWithdrawn, jPlaced, carried, nreq, answer, crashes>>


Ack(i) ==
    /\ alive
    /\ i \in jAccepted
    /\ i \notin acked
    /\ acked' = acked \cup {i}
    /\ UNCHANGED <<alive, submitted, jAccepted, jWithdrawn, jPlaced, carried, nreq, memPending, answer, crashes>>



Prepare ==
    /\ alive
    /\ nreq < MaxRequests
    /\ \E S \in SUBSET memPending :
        /\ carried' = [carried EXCEPT ![nreq + 1] = S]
        /\ jPlaced' = [i \in Inputs |-> IF i \in S THEN nreq + 1 ELSE jPlaced[i]]
        /\ memPending' = memPending \ S
    /\ nreq' = nreq + 1
    /\ UNCHANGED <<alive, submitted, acked, jAccepted, jWithdrawn, answer, crashes>>


Withdraw(i) ==
    /\ alive
    /\ i \in jAccepted
    /\ answer[i] = "none"
    /\ IF jPlaced[i] # 0
       THEN /\ answer' = [answer EXCEPT ![i] = "already_placed"]
            /\ UNCHANGED <<jWithdrawn, memPending>>
       ELSE /\ answer' = [answer EXCEPT ![i] = "withdrawn"]
            /\ jWithdrawn' = jWithdrawn \cup {i}
            /\ memPending' = memPending \ {i}
    /\ UNCHANGED <<alive, submitted, acked, jAccepted, jPlaced, carried, nreq, crashes>>


Crash ==
    /\ alive
    /\ crashes < MaxCrashes
    /\ alive' = FALSE
    /\ memPending' = {}
    /\ crashes' = crashes + 1
    /\ UNCHANGED <<submitted, acked, jAccepted, jWithdrawn, jPlaced, carried, nreq, answer>>


Restore ==
    /\ ~alive
    /\ alive' = TRUE
    /\ memPending' = {i \in jAccepted : jPlaced[i] = 0 /\ i \notin jWithdrawn}
    /\ UNCHANGED <<submitted, acked, jAccepted, jWithdrawn, jPlaced, carried, nreq, answer, crashes>>

Next ==
    \/ \E i \in Inputs : Submit(i) \/ Accept(i) \/ Ack(i) \/ Withdraw(i)
    \/ Prepare
    \/ Crash
    \/ Restore

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------



AckedAreDurable == acked \subseteq jAccepted


ActedInputsAreJournaled == \A r \in Requests : carried[r] \subseteq jAccepted


PlacedOnce ==
    \A i \in Inputs, r1, r2 \in Requests :
        i \in carried[r1] /\ i \in carried[r2] => r1 = r2


PlacementMatchesBody ==
    \A i \in Inputs, r \in Requests : i \in carried[r] <=> jPlaced[i] = r


WithdrawnNeverPlaced ==
    \A i \in jWithdrawn : jPlaced[i] = 0 /\ \A r \in Requests : i \notin carried[r]


WithdrawAnswerTruthful ==
    \A i \in Inputs :
        /\ answer[i] = "withdrawn" => \A r \in Requests : i \notin carried[r]
        /\ answer[i] = "already_placed" => \E r \in Requests : i \in carried[r]

=============================================================================
