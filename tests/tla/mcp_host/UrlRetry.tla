---- MODULE UrlRetry ----































EXTENDS Naturals, FiniteSets

CONSTANTS
    Urls,
    Slots,
    MaxCalls,
    Guard

Js == 1..Urls
SlotIds == 0..(Slots - 1)
NoSlot == Slots

VARIABLES
    calls,
    phase,
    slotOf,
    seen,
    eng,
    ownCall,
    ownUrl,
    truly,
    signal,
    consented,
    said,
    retriedBy,
    proof,
    ended

vars == <<calls, phase, slotOf, seen, eng, ownCall, ownUrl, truly, signal, consented, said, retriedBy, proof, ended>>

Mine == {s \in SlotIds : ownCall[s] = calls /\ eng[s] \in {"shown", "early"} /\ \E j \in Js : slotOf[j] = s}

TypeOK ==
    /\ calls \in 1..MaxCalls
    /\ phase \in {"calling", "consent", "waiting", "done"}
    /\ slotOf \in [Js -> 0..Slots]
    /\ seen \in [Js -> BOOLEAN]
    /\ eng \in [SlotIds -> {"free", "shown", "early", "waiting"}]
    /\ ownCall \in [SlotIds -> 0..MaxCalls]
    /\ ownUrl \in [SlotIds -> 0..Urls]
    /\ truly \in [Js -> BOOLEAN]
    /\ signal \in {"pending", "completed"}
    /\ consented \in BOOLEAN
    /\ said \in {"none", "retry", "cancel"}
    /\ retriedBy \in {"none", "completions", "manual"}
    /\ proof \in [consented : BOOLEAN, said : {"none", "retry", "cancel"}, all : BOOLEAN]
    /\ ended \in {"none", "result", "declined", "cancelled", "fx"}

Init ==
    /\ calls = 1
    /\ phase = "calling"
    /\ slotOf = [j \in Js |-> NoSlot]
    /\ seen = [j \in Js |-> FALSE]
    /\ eng = [s \in SlotIds |-> "free"]
    /\ ownCall = [s \in SlotIds |-> 0]
    /\ ownUrl = [s \in SlotIds |-> 0]
    /\ truly = [j \in Js |-> FALSE]
    /\ signal = "pending"
    /\ consented = FALSE
    /\ said = "none"
    /\ retriedBy = "none"
    /\ proof = [consented |-> FALSE, said |-> "none", all |-> FALSE]
    /\ ended = "none"


ServerRequires ==
    /\ phase = "calling"
    /\ calls < MaxCalls
    /\ \E f \in [Js -> SlotIds] :
        /\ \A j \in Js : eng[f[j]] = "free"
        /\ \A j, k \in Js : j # k => f[j] # f[k]
        /\ eng' = [s \in SlotIds |-> IF \E j \in Js : f[j] = s THEN "shown" ELSE eng[s]]
        /\ ownCall' = [s \in SlotIds |-> IF \E j \in Js : f[j] = s THEN calls ELSE ownCall[s]]
        /\ ownUrl' = [s \in SlotIds |-> IF \E j \in Js : f[j] = s THEN CHOOSE j \in Js : f[j] = s ELSE ownUrl[s]]
        /\ slotOf' = f
    /\ seen' = [j \in Js |-> FALSE]
    /\ truly' = [j \in Js |-> FALSE]
    /\ consented' = FALSE
    /\ signal' = "pending"
    /\ IF Guard
       THEN /\ phase' = "consent"
            /\ ended' = ended
       ELSE /\ phase' = "done"
            /\ ended' = "fx"
    /\ UNCHANGED <<calls, said, retriedBy, proof>>

ServerAnswers ==
    /\ phase = "calling"
    /\ phase' = "done"
    /\ ended' = "result"
    /\ UNCHANGED <<calls, slotOf, seen, eng, ownCall, ownUrl, truly, signal, consented, said, retriedBy, proof>>


ServerCompletes(s) ==
    /\ eng[s] \in {"shown", "waiting"}
    /\ truly' = IF ownCall[s] = calls THEN [truly EXCEPT ![ownUrl[s]] = TRUE] ELSE truly
    /\ IF eng[s] = "shown"
       THEN /\ eng' = [eng EXCEPT ![s] = "early"]
            /\ UNCHANGED <<ownCall, ownUrl, seen, signal>>
       ELSE /\ eng' = [eng EXCEPT ![s] = "free"]
            /\ ownCall' = [ownCall EXCEPT ![s] = 0]
            /\ ownUrl' = [ownUrl EXCEPT ![s] = 0]

            /\ seen' = [j \in Js |-> seen[j] \/ slotOf[j] = s]
            /\ signal' = IF phase = "waiting" /\ \A j \in Js : seen'[j] THEN "completed" ELSE signal
    /\ UNCHANGED <<calls, phase, slotOf, consented, said, retriedBy, proof, ended>>


OtherAsks(s) ==
    /\ eng[s] = "free"
    /\ eng' = [eng EXCEPT ![s] = "shown"]
    /\ slotOf' = IF Guard THEN [j \in Js |-> IF slotOf[j] = s THEN NoSlot ELSE slotOf[j]] ELSE slotOf
    /\ UNCHANGED <<calls, phase, seen, ownCall, ownUrl, truly, signal, consented, said, retriedBy, proof, ended>>

OtherAccepted(s) ==
    /\ ownCall[s] = 0
    /\ eng[s] = "shown"
    /\ eng' = [eng EXCEPT ![s] = "waiting"]
    /\ UNCHANGED <<calls, phase, slotOf, seen, ownCall, ownUrl, truly, signal, consented, said, retriedBy, proof, ended>>

OtherEnds(s) ==
    /\ ownCall[s] = 0
    /\ eng[s] # "free"
    /\ eng' = [eng EXCEPT ![s] = "free"]
    /\ UNCHANGED <<calls, phase, slotOf, seen, ownCall, ownUrl, truly, signal, consented, said, retriedBy, proof, ended>>



SessionEnds ==
    /\ \E s \in SlotIds : eng[s] # "free"
    /\ eng' = [s \in SlotIds |-> "free"]
    /\ ownCall' = [s \in SlotIds |-> 0]
    /\ ownUrl' = [s \in SlotIds |-> 0]
    /\ slotOf' = [j \in Js |-> IF slotOf[j] # NoSlot /\ eng[slotOf[j]] \in {"shown", "early"} THEN NoSlot ELSE slotOf[j]]
    /\ UNCHANGED <<calls, phase, seen, truly, signal, consented, said, retriedBy, proof, ended>>


Again(why, choice) ==
    /\ calls' = calls + 1
    /\ phase' = "calling"
    /\ retriedBy' = why
    /\ proof' = [consented |-> consented, said |-> choice, all |-> \A j \in Js : seen[j]]
    /\ slotOf' = [j \in Js |-> NoSlot]
    /\ seen' = [j \in Js |-> FALSE]
    /\ signal' = "pending"


UserAccepts ==
    /\ phase = "consent"
    /\ LET early == {s \in Mine : eng[s] = "early"}
           seen1 == [j \in Js |-> seen[j] \/ slotOf[j] \in early]
       IN /\ eng' = [s \in SlotIds |-> IF s \in early THEN "free" ELSE IF s \in Mine THEN "waiting" ELSE eng[s]]
          /\ ownCall' = [s \in SlotIds |-> IF s \in early THEN 0 ELSE ownCall[s]]
          /\ ownUrl' = [s \in SlotIds |-> IF s \in early THEN 0 ELSE ownUrl[s]]
          /\ seen' = seen1
          /\ signal' = IF \A j \in Js : seen1[j] THEN "completed" ELSE "pending"
    /\ phase' = "waiting"
    /\ consented' = TRUE
    /\ UNCHANGED <<calls, slotOf, truly, said, retriedBy, proof, ended>>


UserRefuses(how) ==
    /\ phase = "consent"
    /\ eng' = [s \in SlotIds |-> IF s \in Mine THEN "free" ELSE eng[s]]
    /\ ownCall' = [s \in SlotIds |-> IF s \in Mine THEN 0 ELSE ownCall[s]]
    /\ ownUrl' = [s \in SlotIds |-> IF s \in Mine THEN 0 ELSE ownUrl[s]]
    /\ phase' = "done"
    /\ ended' = how
    /\ UNCHANGED <<calls, slotOf, seen, truly, signal, consented, said, retriedBy, proof>>


AutoRetry ==
    /\ phase = "waiting"
    /\ signal = "completed"
    /\ Again("completions", said)
    /\ UNCHANGED <<eng, ownCall, ownUrl, truly, consented, said, ended>>


UserRetries ==
    /\ phase = "waiting"
    /\ said' = "retry"
    /\ Again("manual", "retry")
    /\ UNCHANGED <<eng, ownCall, ownUrl, truly, consented, ended>>


UserCancels ==
    /\ phase = "waiting"
    /\ said' = "cancel"
    /\ phase' = "done"
    /\ ended' = "cancelled"
    /\ UNCHANGED <<calls, slotOf, seen, eng, ownCall, ownUrl, truly, signal, consented, retriedBy, proof>>

Next ==
    \/ ServerRequires
    \/ ServerAnswers
    \/ \E s \in SlotIds : ServerCompletes(s) \/ OtherAsks(s) \/ OtherAccepted(s) \/ OtherEnds(s)
    \/ SessionEnds
    \/ UserAccepts
    \/ \E how \in {"declined", "cancelled"} : UserRefuses(how)
    \/ AutoRetry
    \/ UserRetries
    \/ UserCancels


Fairness ==
    /\ WF_vars(AutoRetry)
    /\ WF_vars(UserCancels)
    /\ WF_vars(UserRefuses("cancelled"))
    /\ WF_vars(ServerRequires \/ ServerAnswers)

Spec == Init /\ [][Next]_vars /\ Fairness



CountsOwnCompletions == \A j \in Js : seen[j] => truly[j]


SeenWhenDone == phase = "waiting" => \A j \in Js : (truly[j] /\ slotOf[j] # NoSlot) => seen[j]


SignalTruth == signal = "completed" => \A j \in Js : seen[j]



RetryOnlyAfterProof ==
    retriedBy # "none" =>
        /\ proof.consented
        /\ proof.said # "cancel"
        /\ retriedBy = "manual" => proof.said = "retry"
        /\ retriedBy = "completions" => proof.all



EndsByUserOrServer == ended # "fx"


HeldCallEnds == (phase \in {"consent", "waiting"}) ~> (phase \in {"calling", "done"})
====
