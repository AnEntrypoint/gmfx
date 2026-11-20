---- MODULE ElicitationRouting ----



























EXTENDS Naturals, FiniteSets

CONSTANTS
    Versions,
    MaxQ,
    Slots,
    Guard

Qs == 1..MaxQ
SlotIds == 0..(Slots - 1)
None == 0

VARIABLES
    version,
    nextQ,
    holder,
    pending,
    calling,
    offered,
    offerKey,
    asking,
    askKey,
    posted,
    answeredBy,
    shown,
    dismissed

vars == <<version, nextQ, holder, pending, calling, offered, offerKey, asking, askKey, posted, answeredBy, shown, dismissed>>

Free == {s \in SlotIds : holder[s] = None}
Lowest(S) == CHOOSE s \in S : \A t \in S : s <= t

TypeOK ==
    /\ version \in Versions
    /\ nextQ \in 1..(MaxQ + 1)
    /\ holder \in [SlotIds -> 0..MaxQ]
    /\ pending \in [Qs -> BOOLEAN]
    /\ calling \in BOOLEAN
    /\ offered \in 0..MaxQ /\ asking \in 0..MaxQ
    /\ offerKey \in 0..MaxQ /\ askKey \in 0..MaxQ
    /\ posted \in [q : 0..MaxQ, key : 0..MaxQ]
    /\ answeredBy \in [Qs -> 0..MaxQ]
    /\ shown \in [Qs -> BOOLEAN]
    /\ dismissed \in [Qs -> BOOLEAN]

Init ==
    /\ version \in Versions
    /\ nextQ = 1
    /\ holder = [s \in SlotIds |-> None]
    /\ pending = [q \in Qs |-> FALSE]
    /\ calling = TRUE
    /\ offered = None /\ offerKey = 0
    /\ asking = None /\ askKey = 0
    /\ posted = [q |-> None, key |-> 0]
    /\ answeredBy = [q \in Qs |-> None]
    /\ shown = [q \in Qs |-> FALSE]
    /\ dismissed = [q \in Qs |-> FALSE]




Ask ==
    /\ nextQ <= MaxQ
    /\ version = "2025" => Free # {}
    /\ LET q == nextQ
           s == IF version = "2025" THEN Lowest(Free) ELSE 0
           take == calling /\ offered = None
       IN /\ nextQ' = nextQ + 1
          /\ holder' = IF version = "2025" /\ take THEN [holder EXCEPT ![s] = q] ELSE holder
          /\ pending' = [pending EXCEPT ![q] = take]
          /\ offered' = IF take THEN q ELSE offered
          /\ offerKey' = IF take THEN (IF version = "2025" THEN s ELSE q) ELSE offerKey

          /\ answeredBy' = IF take THEN answeredBy ELSE [answeredBy EXCEPT ![q] = q]
          /\ dismissed' = [dismissed EXCEPT ![q] = ~take]
    /\ UNCHANGED <<version, calling, asking, askKey, posted, shown>>


Take ==
    /\ offered # None /\ asking = None
    /\ asking' = offered /\ askKey' = offerKey
    /\ offered' = None /\ offerKey' = 0
    /\ shown' = [shown EXCEPT ![offered] = TRUE]
    /\ UNCHANGED <<version, nextQ, holder, pending, calling, posted, answeredBy, dismissed>>


UserAnswers ==
    /\ asking # None /\ posted.q = None
    /\ posted' = [q |-> asking, key |-> askKey]
    /\ asking' = None /\ askKey' = 0
    /\ UNCHANGED <<version, nextQ, holder, pending, calling, offered, offerKey, answeredBy, shown, dismissed>>




Deliver ==
    /\ posted.q # None
    /\ LET target == IF version = "2025" THEN holder[posted.key] ELSE posted.key
           ok == target # None /\ pending[target] /\ (Guard => target = posted.q)
       IN /\ IF ok
             THEN /\ answeredBy' = [answeredBy EXCEPT ![target] = posted.q]
                  /\ pending' = [pending EXCEPT ![target] = FALSE]
                  /\ holder' = IF version = "2025" THEN [holder EXCEPT ![posted.key] = None] ELSE holder
             ELSE UNCHANGED <<answeredBy, pending, holder>>
    /\ posted' = [q |-> None, key |-> 0]
    /\ UNCHANGED <<version, nextQ, calling, offered, offerKey, asking, askKey, shown, dismissed>>





Withdraw(q) ==
    /\ version = "2025" /\ pending[q]
    /\ pending' = [pending EXCEPT ![q] = FALSE]
    /\ holder' = [s \in SlotIds |-> IF holder[s] = q THEN None ELSE holder[s]]
    /\ IF Guard /\ offered = q
         THEN offered' = None /\ offerKey' = 0
         ELSE UNCHANGED <<offered, offerKey>>
    /\ UNCHANGED <<version, nextQ, calling, asking, askKey, posted, answeredBy, shown, dismissed>>




CallEnds ==
    /\ calling
    /\ calling' = FALSE
    /\ offered' = None /\ offerKey' = 0
    /\ pending' = IF version = "2026" THEN [q \in Qs |-> FALSE] ELSE pending
    /\ UNCHANGED <<version, nextQ, holder, asking, askKey, posted, answeredBy, shown, dismissed>>

Next ==
    \/ Ask \/ Take \/ UserAnswers \/ Deliver \/ CallEnds
    \/ \E q \in Qs : Withdraw(q)
    \/ UNCHANGED vars

Fairness == WF_vars(Take) /\ WF_vars(UserAnswers) /\ WF_vars(Deliver)

Spec == Init /\ [][Next]_vars /\ Fairness




AnsweredOnce == \A q \in Qs : answeredBy[q] # None => ~pending[q]


DismissedNeverShown == \A q \in Qs : ~(shown[q] /\ dismissed[q])


OneOnScreen == asking # offered \/ asking = None


AnswerReachesSeen2026 == version = "2026" => \A q \in Qs : answeredBy[q] \in {None, q}




AnswerReachesSeenQuestion == \A q \in Qs : answeredBy[q] \in {None, q}



OfferedStillWaits == Guard => \A q \in Qs : offered = q => pending[q]




ShownIsAnswered == \A q \in Qs : shown[q] ~> (asking # q /\ posted.q # q)
====
