----------------------------- MODULE ToolReplay -----------------------------















EXTENDS Naturals, FiniteSets

CONSTANTS SafeCalls, NeverCalls, MaxCrashes

ASSUME SafeCalls \cap NeverCalls = {}

Calls == SafeCalls \cup NeverCalls


Policy == [c \in Calls |-> IF c \in SafeCalls THEN "safe" ELSE "never"]

VARIABLES
    alive,
    pc,
    inflight,
    jIntent,
    outPending,
    jOutcome,
    starts,
    outcomeWrites,
    lateStart,
    crashes

vars == <<alive, pc, inflight, jIntent, outPending, jOutcome, starts,
          outcomeWrites, lateStart, crashes>>

Steps == {"todo", "intent_sent", "may_run", "running", "finished", "resolved", "down"}
Outcomes == {"none", "result", "interrupted"}

TypeOK ==
    /\ alive \in BOOLEAN
    /\ pc \in [Calls -> Steps]
    /\ inflight \subseteq Calls
    /\ jIntent \subseteq Calls
    /\ outPending \subseteq Calls
    /\ jOutcome \in [Calls -> Outcomes]
    /\ starts \in [Calls -> 0..(MaxCrashes + 1)]
    /\ outcomeWrites \in [Calls -> 0..(MaxCrashes + 2)]
    /\ lateStart \in BOOLEAN
    /\ crashes \in 0..MaxCrashes

Init ==
    /\ alive = TRUE
    /\ pc = [c \in Calls |-> "todo"]
    /\ inflight = {}
    /\ jIntent = {}
    /\ outPending = {}
    /\ jOutcome = [c \in Calls |-> "none"]
    /\ starts = [c \in Calls |-> 0]
    /\ outcomeWrites = [c \in Calls |-> 0]
    /\ lateStart = FALSE
    /\ crashes = 0


SendIntent(c) ==
    /\ alive
    /\ pc[c] = "todo"
    /\ pc' = [pc EXCEPT ![c] = "intent_sent"]
    /\ inflight' = inflight \cup {c}
    /\ UNCHANGED <<alive, jIntent, outPending, jOutcome, starts, outcomeWrites, lateStart, crashes>>


IntentLands(c) ==
    /\ alive
    /\ c \in inflight
    /\ inflight' = inflight \ {c}
    /\ jIntent' = jIntent \cup {c}
    /\ UNCHANGED <<alive, pc, outPending, jOutcome, starts, outcomeWrites, lateStart, crashes>>



Allow(c) ==
    /\ alive
    /\ pc[c] = "intent_sent"
    /\ (c \in jIntent \/ Policy[c] = "safe")
    /\ pc' = [pc EXCEPT ![c] = "may_run"]
    /\ UNCHANGED <<alive, inflight, jIntent, outPending, jOutcome, starts, outcomeWrites, lateStart, crashes>>


Start(c) ==
    /\ alive
    /\ pc[c] = "may_run"
    /\ starts[c] < MaxCrashes + 1
    /\ starts' = [starts EXCEPT ![c] = @ + 1]
    /\ lateStart' = (lateStart \/ jOutcome[c] # "none")
    /\ pc' = [pc EXCEPT ![c] = "running"]
    /\ UNCHANGED <<alive, inflight, jIntent, outPending, jOutcome, outcomeWrites, crashes>>


Finish(c) ==
    /\ alive
    /\ pc[c] = "running"
    /\ pc' = [pc EXCEPT ![c] = "finished"]
    /\ outPending' = outPending \cup {c}
    /\ UNCHANGED <<alive, inflight, jIntent, jOutcome, starts, outcomeWrites, lateStart, crashes>>


OutcomeLands(c) ==
    /\ alive
    /\ c \in outPending
    /\ outPending' = outPending \ {c}
    /\ jOutcome' = [jOutcome EXCEPT ![c] = "result"]
    /\ outcomeWrites' = [outcomeWrites EXCEPT ![c] = @ + 1]
    /\ pc' = [pc EXCEPT ![c] = "resolved"]
    /\ UNCHANGED <<alive, inflight, jIntent, starts, lateStart, crashes>>


Crash ==
    /\ alive
    /\ crashes < MaxCrashes
    /\ \E landedIntents \in SUBSET inflight, landedResults \in SUBSET outPending :
        /\ jIntent' = jIntent \cup landedIntents
        /\ jOutcome' = [c \in Calls |->
                          IF c \in landedResults THEN "result" ELSE jOutcome[c]]
        /\ outcomeWrites' = [c \in Calls |->
                               IF c \in landedResults THEN outcomeWrites[c] + 1
                               ELSE outcomeWrites[c]]
    /\ alive' = FALSE
    /\ pc' = [c \in Calls |-> "down"]
    /\ inflight' = {}
    /\ outPending' = {}
    /\ crashes' = crashes + 1
    /\ UNCHANGED <<starts, lateStart>>



Restore ==
    /\ ~alive
    /\ alive' = TRUE
    /\ pc' = [c \in Calls |->
                IF jOutcome[c] # "none" THEN "resolved"
                ELSE IF c \in jIntent /\ Policy[c] = "safe" THEN "may_run"
                ELSE IF c \in jIntent THEN "resolved"
                ELSE "todo"]
    /\ jOutcome' = [c \in Calls |->
                      IF jOutcome[c] = "none" /\ c \in jIntent /\ Policy[c] = "never"
                      THEN "interrupted" ELSE jOutcome[c]]
    /\ outcomeWrites' = [c \in Calls |->
                           IF jOutcome[c] = "none" /\ c \in jIntent /\ Policy[c] = "never"
                           THEN outcomeWrites[c] + 1 ELSE outcomeWrites[c]]
    /\ UNCHANGED <<inflight, jIntent, outPending, starts, lateStart, crashes>>

Next ==
    \/ \E c \in Calls :
        \/ SendIntent(c)
        \/ IntentLands(c)
        \/ Allow(c)
        \/ Start(c)
        \/ Finish(c)
        \/ OutcomeLands(c)
    \/ Crash
    \/ Restore

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------



NeverRunsTwice == \A c \in Calls : Policy[c] = "never" => starts[c] <= 1


NeverStartsWithoutDurableIntent ==
    \A c \in Calls : Policy[c] = "never" /\ starts[c] > 0 => c \in jIntent


NoStartAfterOutcome == ~lateStart


OneOutcome == \A c \in Calls : outcomeWrites[c] <= 1



InterruptedMeansUnknown ==
    \A c \in Calls :
        jOutcome[c] = "interrupted" => Policy[c] = "never" /\ c \in jIntent

=============================================================================
