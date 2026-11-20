---------------------------- MODULE DurableSession ----------------------------





































































EXTENDS Naturals, Sequences

CONSTANTS
    Workers,
    Tool,

    WritesWait,
    MaxEpoch,
    MaxFreezes,
    SelfStop,
    ClaimFenced,
    MaxCutoffs,
    CutoffBound,
    Heartbeat,
    QueueHeld


ASSUME Tool \in {"lookup", "write", "send"}
ASSUME WritesWait \in BOOLEAN
ASSUME SelfStop \in BOOLEAN
ASSUME ClaimFenced \in BOOLEAN
ASSUME MaxCutoffs \in Nat
ASSUME CutoffBound \in BOOLEAN
ASSUME Heartbeat \in BOOLEAN
ASSUME QueueHeld \in BOOLEAN
ASSUME ~(QueueHeld /\ Heartbeat)

None == "none"

Waiting == {"announce", "model1", "ahead", "tool", "model2"}


Busy == {"model1", "tool", "model2"}
Progress == {"start", "intent", "result", "done"}


Idempotent == Tool \in {"lookup", "write"}

RunsAhead == Tool = "lookup" \/ (Tool = "write" /\ ~WritesWait)

VARIABLES
    pc,
    epoch,
    frozen,
    lease,
    progress,
    runs,
    ids,

    ui,

    freezes,
    froze,
    chain,
    cutoffs,
    seen,
    lapse,


    act

vars == <<pc, epoch, frozen, lease, progress, runs, ids, ui, freezes, froze, chain, cutoffs, seen, lapse, act>>

TypeOK ==
    /\ pc \in [Workers -> {"none", "early", "announce", "model1", "ahead", "tool", "model2", "done", "stopped"}]
    /\ epoch \in [Workers -> 0..MaxEpoch]
    /\ frozen \in [Workers -> BOOLEAN]
    /\ lease \in [holder: Workers \cup {None}, epoch: 0..MaxEpoch, live: BOOLEAN]
    /\ progress \in Progress
    /\ runs \in 0..(MaxEpoch + 1)
    /\ ids \in 0..(MaxEpoch + 1)
    /\ ui \in Seq([e: 0..MaxEpoch, legit: BOOLEAN])
    /\ freezes \in 0..MaxFreezes
    /\ froze \in [Workers -> BOOLEAN]
    /\ chain \in Nat
    /\ cutoffs \in Nat
    /\ seen \in [Workers -> [chain: Nat, progress: Progress, epoch: 0..MaxEpoch, cutoffs: Nat]]
    /\ lapse \in Workers \cup {"none", "open"}
    /\ act \in [name: {"Init", "Start", "Claim", "Announce", "Model1", "Intent", "ToolEnd", "Model2",
                       "Freeze", "Wake", "Deadline", "Expire"},
                w: Workers \cup {None}]

Init ==
    /\ pc = [w \in Workers |-> "none"]
    /\ epoch = [w \in Workers |-> 0]
    /\ frozen = [w \in Workers |-> FALSE]
    /\ lease = [holder |-> None, epoch |-> 0, live |-> FALSE]
    /\ progress = "start"
    /\ runs = 0
    /\ ids = 0
    /\ ui = <<>>
    /\ freezes = 0
    /\ froze = [w \in Workers |-> FALSE]
    /\ chain = 0
    /\ cutoffs = 0
    /\ seen = [w \in Workers |-> [chain |-> 0, progress |-> "start", epoch |-> 0, cutoffs |-> 0]]
    /\ lapse = "none"
    /\ act = [name |-> "Init", w |-> None]


Heads(w) == lease.holder = w /\ lease.epoch = epoch[w]


Line(w) == [e |-> epoch[w], legit |-> Heads(w)]


MaybeLine(w) == ui' \in {ui, Append(ui, Line(w))}



ShownAt(lines) == {i \in 1..Len(lines) : \A j \in 1..(i - 1) : lines[j].e <= lines[i].e}


Read == [chain |-> chain, progress |-> progress, epoch |-> lease.epoch, cutoffs |-> cutoffs]



CanClaim(w) == progress # "done" /\ (lease.holder = None \/ (~lease.live /\ (~QueueHeld \/ lapse = w)))






Start(w) ==
    /\ pc[w] \in {"none", "stopped"}
    /\ ~frozen[w]
    /\ lease.epoch < MaxEpoch
    /\ \/ /\ CanClaim(w)
          /\ UNCHANGED lapse
       \/ /\ QueueHeld
          /\ progress # "done"
          /\ lease.holder # None
          /\ ~lease.live
          /\ lapse = "open"
          /\ lapse' = w
    /\ pc' = [pc EXCEPT ![w] = "early"]
    /\ seen' = [seen EXCEPT ![w] = Read]
    /\ UNCHANGED <<epoch, frozen, lease, progress, runs, ids, ui, freezes, froze, chain, cutoffs>>
    /\ act' = [name |-> "Start", w |-> w]






Claim(w) ==
    /\ pc[w] = "early"
    /\ ~frozen[w]
    /\ IF chain = seen[w].chain \/ ~ClaimFenced
          THEN /\ seen[w].epoch < MaxEpoch
               /\ lease' = [holder |-> w, epoch |-> seen[w].epoch + 1, live |-> TRUE]
               /\ epoch' = [epoch EXCEPT ![w] = seen[w].epoch + 1]
               /\ chain' = chain + 1
               /\ pc' = [pc EXCEPT ![w] = "announce"]
               /\ froze' = [froze EXCEPT ![w] = FALSE]
               /\ lapse' = "none"
               /\ UNCHANGED seen
          ELSE /\ UNCHANGED <<lease, epoch, chain, froze, lapse>>
               /\ IF CanClaim(w)
                     THEN /\ pc' = [pc EXCEPT ![w] = "early"]
                          /\ seen' = [seen EXCEPT ![w] = Read]
                     ELSE /\ pc' = [pc EXCEPT ![w] = "none"]
                          /\ UNCHANGED seen
    /\ UNCHANGED <<frozen, progress, runs, ids, ui, freezes, cutoffs>>
    /\ act' = [name |-> "Claim", w |-> w]












Announce(w) ==
    /\ pc[w] = "announce"
    /\ ~frozen[w]
    /\ LET from == seen[w].progress
           spent == CutoffBound /\ seen[w].cutoffs >= MaxCutoffs
           rerun == from = "intent" /\ Idempotent /\ ~spent
       IN IF spent /\ from \in {"start", "result"}
          THEN /\ UNCHANGED runs
               /\ IF Heads(w)
                     THEN /\ progress' = "done"
                          /\ pc' = [pc EXCEPT ![w] = "done"]
                          /\ lease' = [lease EXCEPT !.holder = None, !.live = FALSE]

                          /\ ui' = ui \o <<Line(w), Line(w)>>
                          /\ chain' = chain + 1
                          /\ cutoffs' = 0
                          /\ lapse' = "none"
                     ELSE /\ pc' = [pc EXCEPT ![w] = "stopped"]
                          /\ ui' \in {Append(ui, Line(w)), ui \o <<Line(w), Line(w)>>}
                          /\ UNCHANGED <<progress, lease, chain, cutoffs, lapse>>
          ELSE /\ pc' = [pc EXCEPT ![w] =
                          CASE from = "start" -> "model1"
                            [] from = "intent" -> IF rerun THEN "tool" ELSE "model2"
                            [] from \in {"result", "done"} -> "model2"]
               /\ runs' = IF rerun THEN runs + 1 ELSE runs


               /\ ui' = IF from = "intent" THEN ui \o <<Line(w), Line(w)>> ELSE Append(ui, Line(w))

               /\ IF from = "intent" /\ ~rerun /\ Heads(w)
                     THEN /\ progress' = "result"
                          /\ cutoffs' = 0
                     ELSE UNCHANGED <<progress, cutoffs>>
               /\ UNCHANGED <<lease, chain, lapse>>
    /\ UNCHANGED <<epoch, frozen, ids, freezes, froze, seen>>
    /\ act' = [name |-> "Announce", w |-> w]











Model1(w) ==
    /\ pc[w] = "model1"
    /\ ~frozen[w]
    /\ IF RunsAhead
          THEN /\ runs' = runs + 1
               /\ ids' = ids + 1
               /\ \/ /\ pc' = [pc EXCEPT ![w] = "ahead"]
                     /\ ui' = Append(ui, Line(w))
                     /\ \/ UNCHANGED <<chain, cutoffs>>
                        \/ /\ Heads(w)
                           /\ chain' = chain + 1
                           /\ cutoffs' = 0
                  \/ /\ ~Heads(w)
                     /\ pc' = [pc EXCEPT ![w] = "stopped"]
                     /\ MaybeLine(w)
                     /\ UNCHANGED <<chain, cutoffs>>
               /\ UNCHANGED progress
          ELSE /\ IF Heads(w)
                     THEN /\ progress' = "intent"
                          /\ runs' = runs + 1
                          /\ ids' = ids + 1
                          /\ pc' = [pc EXCEPT ![w] = "tool"]
                          /\ ui' = Append(ui, Line(w))
                     ELSE /\ pc' = [pc EXCEPT ![w] = "stopped"]
                          /\ MaybeLine(w)
                          /\ UNCHANGED <<progress, runs, ids>>
               /\ chain' = IF Heads(w) THEN chain + 1 ELSE chain
               /\ cutoffs' = IF Heads(w) THEN 0 ELSE cutoffs
    /\ UNCHANGED <<epoch, frozen, lease, freezes, froze, seen, lapse>>
    /\ act' = [name |-> "Model1", w |-> w]




Intent(w) ==
    /\ pc[w] = "ahead"
    /\ ~frozen[w]
    /\ IF Heads(w)
          THEN /\ progress' = "intent"
               /\ pc' = [pc EXCEPT ![w] = "tool"]
               /\ chain' = chain + 1
               /\ cutoffs' = 0
               /\ UNCHANGED ui
          ELSE /\ pc' = [pc EXCEPT ![w] = "stopped"]
               /\ MaybeLine(w)
               /\ UNCHANGED <<progress, chain, cutoffs>>
    /\ UNCHANGED <<epoch, frozen, lease, runs, ids, freezes, froze, seen, lapse>>
    /\ act' = [name |-> "Intent", w |-> w]


ToolEnd(w) ==
    /\ pc[w] = "tool"
    /\ ~frozen[w]
    /\ IF Heads(w)
          THEN /\ progress' = "result"
               /\ pc' = [pc EXCEPT ![w] = "model2"]
               /\ ui' = Append(ui, Line(w))
          ELSE /\ pc' = [pc EXCEPT ![w] = "stopped"]
               /\ MaybeLine(w)
               /\ UNCHANGED progress
    /\ chain' = IF Heads(w) THEN chain + 1 ELSE chain
    /\ cutoffs' = IF Heads(w) THEN 0 ELSE cutoffs
    /\ UNCHANGED <<epoch, frozen, lease, runs, ids, freezes, froze, seen, lapse>>
    /\ act' = [name |-> "ToolEnd", w |-> w]


Model2(w) ==
    /\ pc[w] = "model2"
    /\ ~frozen[w]
    /\ IF Heads(w)
          THEN /\ progress' = "done"
               /\ pc' = [pc EXCEPT ![w] = "done"]
               /\ lease' = [lease EXCEPT !.holder = None, !.live = FALSE]
               /\ lapse' = "none"

               /\ ui' = ui \o <<Line(w), Line(w)>>
          ELSE /\ pc' = [pc EXCEPT ![w] = "stopped"]
               /\ MaybeLine(w)
               /\ UNCHANGED <<progress, lease, lapse>>
    /\ chain' = IF Heads(w) THEN chain + 1 ELSE chain
    /\ cutoffs' = IF Heads(w) THEN 0 ELSE cutoffs
    /\ UNCHANGED <<epoch, frozen, runs, ids, freezes, froze, seen>>
    /\ act' = [name |-> "Model2", w |-> w]



Freeze(w) ==
    /\ pc[w] \in Waiting
    /\ ~frozen[w]
    /\ freezes < MaxFreezes
    /\ frozen' = [frozen EXCEPT ![w] = TRUE]
    /\ freezes' = freezes + 1
    /\ froze' = [froze EXCEPT ![w] = TRUE]
    /\ lease' = IF lease.holder = w THEN [lease EXCEPT !.live = FALSE] ELSE lease
    /\ lapse' = IF QueueHeld /\ lease.holder = w /\ lapse = "none" THEN "open" ELSE lapse
    /\ UNCHANGED <<pc, epoch, progress, runs, ids, ui, chain, cutoffs, seen>>
    /\ act' = [name |-> "Freeze", w |-> w]




Wake(w) ==
    /\ frozen[w]
    /\ frozen' = [frozen EXCEPT ![w] = FALSE]
    /\ \/ UNCHANGED <<pc, lease, chain>>
       \/ /\ Heartbeat
          /\ Heads(w)
          /\ lease' = [lease EXCEPT !.live = TRUE]
          /\ chain' = chain + 1
          /\ UNCHANGED pc
       \/ /\ Heartbeat
          /\ ~Heads(w)
          /\ pc' = [pc EXCEPT ![w] = "stopped"]
          /\ UNCHANGED <<lease, chain>>
    /\ UNCHANGED <<epoch, progress, runs, ids, ui, freezes, froze, cutoffs, seen, lapse>>
    /\ act' = [name |-> "Wake", w |-> w]







Deadline(w) ==
    /\ SelfStop
    /\ pc[w] \in Busy
    /\ ~frozen[w]
    /\ IF Heads(w)
          THEN /\ ui' = Append(ui, Line(w))
               /\ chain' = chain + 1

               /\ cutoffs' = cutoffs + 1
               /\ \/ /\ lease.epoch < MaxEpoch
                     /\ lease' = [holder |-> w, epoch |-> lease.epoch + 1, live |-> TRUE]
                     /\ epoch' = [epoch EXCEPT ![w] = lease.epoch + 1]
                     /\ pc' = [pc EXCEPT ![w] = "announce"]
                     /\ froze' = [froze EXCEPT ![w] = FALSE]

                     /\ seen' = [seen EXCEPT ![w] = [chain |-> chain + 1, progress |-> progress, epoch |-> lease.epoch, cutoffs |-> cutoffs + 1]]
                  \/ /\ lease' = [lease EXCEPT !.holder = None, !.live = FALSE]
                     /\ pc' = [pc EXCEPT ![w] = "none"]
                     /\ UNCHANGED <<epoch, froze, seen>>
               /\ lapse' = "none"
          ELSE /\ pc' = [pc EXCEPT ![w] = "stopped"]
               /\ MaybeLine(w)
               /\ UNCHANGED <<epoch, lease, froze, chain, cutoffs, seen, lapse>>
    /\ UNCHANGED <<frozen, progress, runs, ids, freezes>>
    /\ act' = [name |-> "Deadline", w |-> w]



Expire(w) ==
    /\ ~SelfStop
    /\ pc[w] \in Busy
    /\ ~frozen[w]
    /\ Heads(w)
    /\ lease.live
    /\ lease' = [lease EXCEPT !.live = FALSE]
    /\ UNCHANGED <<pc, epoch, frozen, progress, runs, ids, ui, freezes, froze, chain, cutoffs, seen, lapse>>
    /\ act' = [name |-> "Expire", w |-> w]

Next ==
    \E w \in Workers :
        \/ Start(w) \/ Claim(w) \/ Announce(w) \/ Model1(w) \/ Intent(w) \/ ToolEnd(w) \/ Model2(w)
        \/ Freeze(w) \/ Wake(w) \/ Deadline(w) \/ Expire(w)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------



EffectsAtMostOnce == Tool = "send" => runs <= 1



HandoffsBounded == cutoffs <= MaxCutoffs


CallAfterIntent == Tool \in {"write", "send"} => (runs > 0 => progress # "start")






OneExecutionId == Tool \in {"write", "send"} => ids <= 1



EveryCallAfterIntent == runs > 0 => progress # "start"



IdsAtMostOne == ids <= 1


DoneByHead == progress = "done" => \E w \in Workers : pc[w] = "done"


LegitShown == \A i \in 1..Len(ui) : ui[i].legit => i \in ShownAt(ui)

Active(w) == pc[w] \in Waiting /\ ~frozen[w]




TwoActiveNeedsFreeze ==
    \A v, w \in Workers : v # w /\ Active(v) /\ Active(w) => froze[v] \/ froze[w]




NoStaleShown == \A i \in ShownAt(ui) : ui[i].legit


UiInOrder == \A i \in 1..(Len(ui) - 1) : ui[i].e <= ui[i + 1].e


NotTwoActive ==
    ~(\E v, w \in Workers :
        /\ v # w
        /\ Active(v)
        /\ Active(w))
=============================================================================
