---- MODULE FullDetailOrder ----






















EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS Steps, MaxFails, PinTop, RecordsSaved, SplitFailures

ASSUME Steps \in Nat \ {0} /\ MaxFails \in Nat
ASSUME PinTop \in BOOLEAN /\ SplitFailures \in BOOLEAN
ASSUME RecordsSaved \in {"always", "commit", "never"}

Item(k, t, a) == [k |-> k, t |-> t, a |-> a]
Prompt == Item(0, "prompt", 0)
IsRecord(it) == it.t \in {"fail", "rec"}

VARIABLES
    events,
    live,
    step,
    fails,
    stage,
    saved,
    committed,
    crashed,
    replay

vars == <<events, live, step, fails, stage, saved, committed, crashed, replay>>

Init ==
    /\ events = <<Prompt>>
    /\ live = <<Prompt>>
    /\ step = 1
    /\ fails = 0
    /\ stage = "send"
    /\ saved = 0
    /\ committed = FALSE
    /\ crashed = FALSE
    /\ replay = <<>>

Running == ~committed /\ ~crashed
Happen(it) == events' = Append(events, it)


Fail ==
    /\ Running /\ stage = "send" /\ fails < MaxFails
    /\ Happen(Item(step, "fail", fails + 1))
    /\ fails' = fails + 1
    /\ UNCHANGED <<live, step, stage, saved, committed, crashed, replay>>


Text ==
    /\ Running /\ stage = "send"
    /\ Happen(Item(step, "text", 0))
    /\ stage' = "settle"
    /\ UNCHANGED <<live, step, fails, saved, committed, crashed, replay>>


Settle ==
    /\ Running /\ stage = "settle"
    /\ Happen(Item(step, "rec", 0))
    /\ stage' = IF step < Steps THEN "tools" ELSE "done"
    /\ UNCHANGED <<live, step, fails, saved, committed, crashed, replay>>


Tools ==
    /\ Running /\ stage = "tools"
    /\ Happen(Item(step, "tool", 0))
    /\ step' = step + 1
    /\ fails' = 0
    /\ stage' = "send"
    /\ UNCHANGED <<live, saved, committed, crashed, replay>>


Deliver ==
    /\ Len(live) < Len(events)
    /\ LET it == events[Len(live) + 1] IN
         live' = IF PinTop /\ IsRecord(it) THEN <<it>> \o live ELSE Append(live, it)
    /\ UNCHANGED <<events, step, fails, stage, saved, committed, crashed, replay>>



Has(prefix, it) == \E i \in 1..Len(prefix) : prefix[i] = it
FailsIn(prefix, k) == Cardinality({i \in 1..Len(prefix) : prefix[i].k = k /\ prefix[i].t = "fail"})
Encode(prefix, records) ==
    [k \in 1..Steps |->
        [fails |-> IF records THEN FailsIn(prefix, k) ELSE 0,
         text |-> Has(prefix, Item(k, "text", 0)),
         rec |-> records /\ Has(prefix, Item(k, "rec", 0)),
         tool |-> Has(prefix, Item(k, "tool", 0))]]


FailSeq(k, n) == [i \in 1..n |-> Item(k, "fail", i)]
One(cond, it) == IF cond THEN <<it>> ELSE <<>>
StepSeq(s, k) ==
    LET text == One(s[k].text, Item(k, "text", 0))
        rec == One(s[k].rec, Item(k, "rec", 0))
        tool == One(s[k].tool, Item(k, "tool", 0))
    IN IF SplitFailures
       THEN FailSeq(k, s[k].fails) \o text \o rec \o tool
       ELSE text \o FailSeq(k, s[k].fails) \o rec \o tool
RECURSIVE PlaceFrom(_, _)
PlaceFrom(s, k) == IF k > Steps THEN <<>> ELSE StepSeq(s, k) \o PlaceFrom(s, k + 1)
Place(s) == <<Prompt>> \o PlaceFrom(s, 1)


Save ==
    /\ Running /\ saved < Len(events)
    /\ saved' = Len(events)
    /\ UNCHANGED <<events, live, step, fails, stage, committed, crashed, replay>>

RecordsIn(isCommit) ==
    CASE RecordsSaved = "always" -> TRUE
      [] RecordsSaved = "commit" -> isCommit
      [] OTHER -> FALSE

Commit ==
    /\ Running /\ stage = "done"
    /\ committed' = TRUE
    /\ saved' = Len(events)
    /\ replay' = Place(Encode(events, RecordsIn(TRUE)))
    /\ UNCHANGED <<events, live, step, fails, stage, crashed>>



Crash ==
    /\ Running
    /\ crashed' = TRUE
    /\ replay' = IF saved = 0 THEN <<>>
                 ELSE Place(Encode(SubSeq(events, 1, saved), RecordsIn(FALSE)))
    /\ UNCHANGED <<events, live, step, fails, stage, saved, committed>>

Next == Fail \/ Text \/ Settle \/ Tools \/ Deliver \/ Save \/ Commit \/ Crash

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ live \in Seq([k : 0..Steps, t : {"prompt", "fail", "text", "rec", "tool"}, a : 0..MaxFails])
    /\ saved \in 0..Len(events)


LivePrefixOfEvents == live = SubSeq(events, 1, Len(live))


PromptFirst == live[1] = Prompt



ReplayMatchesSaved ==
    (committed \/ crashed) => replay = SubSeq(events, 1, saved)
====
