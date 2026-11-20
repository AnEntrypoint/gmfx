----------------------------- MODULE PromptIntake -----------------------------



































EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    N,
    MaxFaults,
    Gate,
    CloseCheck,
    GateReleasesOnFailure,
    AbortWithdraws

ASSUME N \in Nat /\ MaxFaults \in Nat
ASSUME Gate \in BOOLEAN /\ CloseCheck \in BOOLEAN /\ GateReleasesOnFailure \in BOOLEAN /\ AbortWithdraws \in BOOLEAN

Prompts == 1..N
Kinds == {"text", "image"}
Phases == {"unmade", "early", "preparing", "sending", "stored", "failed", "refused", "withdrawn"}

VARIABLES
    made,
    kind,
    early,
    before,
    ph,
    acc,
    res,
    aborted,
    cancel,
    log,
    ran,
    open,
    done,
    active,
    closed,
    faults,
    prepAtClose,
    act

vars == <<made, kind, early, before, ph, acc, res, aborted, cancel, log, ran, open, done,
          active, closed, faults, prepAtClose, act>>

None == "none"
Act(name, p) == [name |-> name, p |-> p, kind |-> None, early |-> FALSE]

TypeOK ==
    /\ made \in 0..N
    /\ kind \in [Prompts -> Kinds \cup {None}]
    /\ early \in [Prompts -> BOOLEAN]
    /\ before \in [Prompts -> 0..N]
    /\ ph \in [Prompts -> Phases]
    /\ acc \in [Prompts -> {"pending", "resolved", "rejected"}]
    /\ res \in [Prompts -> {"pending", "end", "cancelled", "rejected"}]
    /\ aborted \in [Prompts -> BOOLEAN]
    /\ cancel \in [Prompts -> {"none", "held", "stored"}]
    /\ log \in Seq(Prompts)
    /\ ran \in [Prompts -> BOOLEAN]
    /\ open \in 0..N
    /\ done \subseteq Prompts
    /\ active \in BOOLEAN
    /\ closed \in BOOLEAN
    /\ faults \in 0..MaxFaults
    /\ prepAtClose \subseteq Prompts
    /\ act \in [name: {"Init", "Make", "Released", "Prepared", "PrepareFail", "Store", "StoreFail",
                       "Abort", "CancelStore", "Close", "Start", "Skip", "CancelRun", "End", "Finished"},
                p: 0..N, kind: Kinds \cup {None}, early: BOOLEAN]

Init ==
    /\ made = 0
    /\ kind = [i \in Prompts |-> None]
    /\ early = [i \in Prompts |-> FALSE]
    /\ before = [i \in Prompts |-> 0]
    /\ ph = [i \in Prompts |-> "unmade"]
    /\ acc = [i \in Prompts |-> "pending"]
    /\ res = [i \in Prompts |-> "pending"]
    /\ aborted = [i \in Prompts |-> FALSE]
    /\ cancel = [i \in Prompts |-> "none"]
    /\ log = <<>>
    /\ ran = [i \in Prompts |-> FALSE]
    /\ open = 0
    /\ done = {}
    /\ active = FALSE
    /\ closed = FALSE
    /\ faults = 0
    /\ prepAtClose = {}
    /\ act = Act("Init", 0)

Stored == {log[k] : k \in 1..Len(log)}
Pending(d) == SelectSeq(log, LAMBDA i : i \notin d)



Waiting == {j \in 1..made : kind[j] = "image" /\ ~early[j] /\ acc[j] = "pending"}
GateNow == IF Gate /\ Waiting # {} THEN CHOOSE j \in Waiting : \A k \in Waiting : k <= j ELSE 0




Ready(i) ==
    IF before[i] = 0 THEN TRUE
    ELSE IF GateReleasesOnFailure
         THEN \A j \in 1..before[i] : (kind[j] = "image" /\ ~early[j]) => acc[j] # "pending"
         ELSE acc[before[i]] = "resolved"


Reject(i, phase) ==
    /\ ph' = [ph EXCEPT ![i] = phase]
    /\ acc' = [acc EXCEPT ![i] = "rejected"]
    /\ res' = [res EXCEPT ![i] = "rejected"]

Make(i, k, e) ==
    /\ ~closed
    /\ made = i - 1
    /\ made' = i
    /\ kind' = [kind EXCEPT ![i] = k]
    /\ early' = [early EXCEPT ![i] = e]
    /\ IF e
         THEN /\ ph' = [ph EXCEPT ![i] = "early"]
              /\ acc' = [acc EXCEPT ![i] = "resolved"]
              /\ res' = [res EXCEPT ![i] = "cancelled"]
              /\ UNCHANGED before
         ELSE /\ before' = [before EXCEPT ![i] = GateNow]
              /\ ph' = [ph EXCEPT ![i] = IF k = "text" /\ GateNow = 0 THEN "sending" ELSE "preparing"]
              /\ UNCHANGED <<acc, res>>
    /\ act' = [name |-> "Make", p |-> i, kind |-> k, early |-> e]
    /\ UNCHANGED <<aborted, cancel, log, ran, open, done, active, closed, faults, prepAtClose>>


Released(i) ==
    /\ ph[i] = "preparing" /\ kind[i] = "text" /\ Ready(i)
    /\ IF closed /\ CloseCheck
         THEN Reject(i, "refused")
         ELSE /\ ph' = [ph EXCEPT ![i] = "sending"]
              /\ UNCHANGED <<acc, res>>
    /\ act' = Act("Released", i)
    /\ UNCHANGED <<made, kind, early, before, aborted, cancel, log, ran, open, done, active, closed, faults, prepAtClose>>

Prepared(i) ==
    /\ ph[i] = "preparing" /\ kind[i] = "image" /\ Ready(i)
    /\ IF closed /\ CloseCheck
         THEN Reject(i, "refused")
         ELSE /\ ph' = [ph EXCEPT ![i] = "sending"]
              /\ UNCHANGED <<acc, res>>
    /\ act' = Act("Prepared", i)
    /\ UNCHANGED <<made, kind, early, before, aborted, cancel, log, ran, open, done, active, closed, faults, prepAtClose>>

PrepareFail(i) ==
    /\ ph[i] = "preparing" /\ kind[i] = "image" /\ Ready(i)
    /\ faults < MaxFaults
    /\ Reject(i, "failed")
    /\ faults' = faults + 1
    /\ act' = Act("PrepareFail", i)
    /\ UNCHANGED <<made, kind, early, before, aborted, cancel, log, ran, open, done, active, closed, prepAtClose>>

Store(i) ==
    /\ ph[i] = "sending"
    /\ log' = Append(log, i)
    /\ ph' = [ph EXCEPT ![i] = "stored"]
    /\ acc' = [acc EXCEPT ![i] = "resolved"]
    /\ act' = Act("Store", i)
    /\ UNCHANGED <<made, kind, early, before, res, aborted, cancel, ran, open, done, active, closed, faults, prepAtClose>>

StoreFail(i) ==
    /\ ph[i] = "sending"
    /\ faults < MaxFaults
    /\ Reject(i, "failed")
    /\ faults' = faults + 1
    /\ act' = Act("StoreFail", i)
    /\ UNCHANGED <<made, kind, early, before, aborted, cancel, log, ran, open, done, active, closed, prepAtClose>>





Abort(i) ==
    /\ ph[i] \notin {"unmade", "early"}
    /\ ~aborted[i] /\ res[i] = "pending"
    /\ aborted' = [aborted EXCEPT ![i] = TRUE]
    /\ IF ph[i] = "preparing" /\ AbortWithdraws
         THEN /\ ph' = [ph EXCEPT ![i] = "withdrawn"]
              /\ acc' = [acc EXCEPT ![i] = "resolved"]
              /\ res' = [res EXCEPT ![i] = "cancelled"]
              /\ UNCHANGED cancel
         ELSE /\ cancel' = [cancel EXCEPT ![i] = "held"]
              /\ UNCHANGED <<ph, acc, res>>
    /\ act' = Act("Abort", i)
    /\ UNCHANGED <<made, kind, early, before, log, ran, open, done, active, closed, faults, prepAtClose>>

CancelStore(i) ==
    /\ cancel[i] = "held"
    /\ cancel' = [cancel EXCEPT ![i] = "stored"]
    /\ act' = Act("CancelStore", i)
    /\ UNCHANGED <<made, kind, early, before, ph, acc, res, aborted, log, ran, open, done, active, closed, faults, prepAtClose>>

Close ==
    /\ ~closed
    /\ closed' = TRUE
    /\ prepAtClose' = {i \in Prompts : ph[i] = "preparing"}
    /\ act' = Act("Close", 0)
    /\ UNCHANGED <<made, kind, early, before, ph, acc, res, aborted, cancel, log, ran, open, done, active, faults>>


CanRun == open = 0 /\ (~closed \/ active) /\ Pending(done) # <<>>

Start(i) ==
    /\ CanRun /\ Head(Pending(done)) = i /\ cancel[i] # "stored"
    /\ open' = i
    /\ ran' = [ran EXCEPT ![i] = TRUE]
    /\ active' = TRUE
    /\ act' = Act("Start", i)
    /\ UNCHANGED <<made, kind, early, before, ph, acc, res, aborted, cancel, log, done, closed, faults, prepAtClose>>


Ended(i, how) ==
    /\ done' = done \cup {i}
    /\ res' = [res EXCEPT ![i] = how]
    /\ active' = (Pending(done \cup {i}) # <<>>)

Skip(i) ==
    /\ CanRun /\ Head(Pending(done)) = i /\ cancel[i] = "stored"
    /\ Ended(i, "cancelled")
    /\ act' = Act("Skip", i)
    /\ UNCHANGED <<made, kind, early, before, ph, acc, aborted, cancel, log, ran, open, closed, faults, prepAtClose>>

CancelRun(i) ==
    /\ open = i /\ i # 0 /\ cancel[i] = "stored"
    /\ open' = 0
    /\ Ended(i, "cancelled")
    /\ act' = Act("CancelRun", i)
    /\ UNCHANGED <<made, kind, early, before, ph, acc, aborted, cancel, log, ran, closed, faults, prepAtClose>>

End(i) ==
    /\ open = i /\ i # 0 /\ cancel[i] # "stored"
    /\ open' = 0
    /\ Ended(i, "end")
    /\ act' = Act("End", i)
    /\ UNCHANGED <<made, kind, early, before, ph, acc, aborted, cancel, log, ran, closed, faults, prepAtClose>>


Settled == \A i \in 1..made : acc[i] # "pending"
Finished == Settled /\ UNCHANGED vars

Next ==
    \/ \E i \in Prompts, k \in Kinds, e \in BOOLEAN : Make(i, k, e)
    \/ \E i \in Prompts :
         \/ Released(i) \/ Prepared(i) \/ PrepareFail(i) \/ Store(i) \/ StoreFail(i)
         \/ Abort(i) \/ CancelStore(i) \/ Start(i) \/ Skip(i) \/ CancelRun(i) \/ End(i)
    \/ Close
    \/ Finished

Spec == Init /\ [][Next]_vars




Auto == \E i \in Prompts : Released(i) \/ Start(i) \/ Skip(i) \/ CancelRun(i)
Quiet == ~ENABLED Auto
DriverStep ==
    \/ \E i \in Prompts, k \in Kinds, e \in BOOLEAN : Make(i, k, e)
    \/ \E i \in Prompts :
         Prepared(i) \/ PrepareFail(i) \/ Store(i) \/ StoreFail(i) \/ Abort(i) \/ CancelStore(i) \/ End(i)
    \/ Close
DriveSpec == Init /\ [][(Quiet /\ DriverStep) \/ Auto \/ Finished]_vars






ImageOrder ==
    \A a, b \in 1..Len(log) : a < b => ~(log[b] < log[a] /\ kind[log[b]] = "image")



StoredIffAccepted ==
    \A i \in 1..made : (acc[i] = "resolved") <=> (i \in Stored \/ ph[i] \in {"early", "withdrawn"})



CancelOnlyWhenSent == \A i \in Prompts : cancel[i] # "none" => ph[i] \in {"sending", "stored", "failed"}


WithdrawnNeverStored == \A i \in Prompts : ph[i] = "withdrawn" => i \notin Stored /\ cancel[i] = "none"

NeverStoredTwice == \A a, b \in 1..Len(log) : a # b => log[a] # log[b]


ClosedStopsPreparing == prepAtClose \cap Stored = {}


CancelledOnlyOwn == \A i \in Prompts : res[i] = "cancelled" => (aborted[i] \/ early[i])


NoRunAfterRejected == \A i \in Prompts : ran[i] => acc[i] = "resolved"


RunsStored == open # 0 => (open \in Stored /\ open \notin done)
=============================================================================
