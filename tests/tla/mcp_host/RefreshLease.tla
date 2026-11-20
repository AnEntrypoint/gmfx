---- MODULE RefreshLease ----




























EXTENDS Naturals

CONSTANTS
    Others,
    CallMax,
    MaxCalls,
    Budget,
    Slack,
    RefreshMax

R == "refresher"

VARIABLES
    now,
    sOwner,
    storeStamp,
    oState,
    oNeeds, oCalls, oIn, oCallAt, oStamped,
    phase,
    rHold,
    rCalls, rIn, rCallAt, rStamped,
    rWaitAt,
    netAt,
    rStamp,
    frozen,
    w

vars == <<now, sOwner, storeStamp, oState, oNeeds, oCalls, oIn, oCallAt, oStamped,
          phase, rHold, rCalls, rIn, rCallAt, rStamped, rWaitAt, netAt, rStamp, frozen, w>>


WStart == 0

Max(a, b) == IF a > b THEN a ELSE b


RNeeds == IF phase = "lookup" THEN 1 ELSE 2

RWantsStore == phase \in {"lookup", "save"} /\ ~rHold
RLive == phase # "done" /\ ~(R \in frozen)
OLive(o) == sOwner = o /\ ~(o \in frozen)
OOver(o) == oIn[o] /\ now - oCallAt[o] >= CallMax
ROver == rIn /\ now - rCallAt >= CallMax


RStoreExpired == now >= Max(storeStamp, rWaitAt) + Budget + Slack


GoAhead ==
    now >= Max(Max(rStamp, WStart) + RefreshMax, Max(storeStamp, WStart) + Budget + Slack) + Slack

TypeOK ==
    /\ sOwner \in Others \cup {R, "none"}
    /\ phase \in {"lookup", "network", "save", "done"}
    /\ w \in {"waiting", "got", "went"}

Init ==
    /\ now = 0
    /\ sOwner = "none" /\ storeStamp = 0
    /\ oState = [o \in Others |-> "ready"]
    /\ oNeeds \in [Others -> 1..MaxCalls]
    /\ oCalls = [o \in Others |-> 0]
    /\ oIn = [o \in Others |-> FALSE]
    /\ oCallAt = [o \in Others |-> 0]
    /\ oStamped = [o \in Others |-> FALSE]

    /\ phase = "lookup" /\ rHold = FALSE /\ rCalls = 0 /\ rIn = FALSE /\ rCallAt = 0
    /\ rStamped = FALSE /\ rWaitAt = 0 /\ netAt = 0 /\ rStamp = 0
    /\ frozen = {}
    /\ w = "waiting"

OVars == <<oState, oNeeds, oCalls, oIn, oCallAt, oStamped>>
RVars == <<phase, rHold, rCalls, rIn, rCallAt, rStamped, rWaitAt, netAt, rStamp>>


OAcquire(o) ==
    /\ sOwner = "none" /\ oState[o] = "ready" /\ ~(o \in frozen)
    /\ sOwner' = o
    /\ oState' = [oState EXCEPT ![o] = "holding"]
    /\ UNCHANGED <<now, storeStamp, oNeeds, oCalls, oIn, oCallAt, oStamped, frozen, w>> /\ UNCHANGED RVars

OStamp(o) ==
    /\ OLive(o) /\ ~oStamped[o] /\ ~oIn[o] /\ oCalls[o] < oNeeds[o]
    /\ oStamped' = [oStamped EXCEPT ![o] = TRUE]
    /\ storeStamp' = now
    /\ UNCHANGED <<now, sOwner, oState, oNeeds, oCalls, oIn, oCallAt, frozen, w>> /\ UNCHANGED RVars

OStartCall(o) ==
    /\ OLive(o) /\ oStamped[o] /\ ~oIn[o]
    /\ oIn' = [oIn EXCEPT ![o] = TRUE]
    /\ oCallAt' = [oCallAt EXCEPT ![o] = now]
    /\ oStamped' = [oStamped EXCEPT ![o] = FALSE]
    /\ UNCHANGED <<now, sOwner, storeStamp, oState, oNeeds, oCalls, frozen, w>> /\ UNCHANGED RVars

OEndCall(o) ==
    /\ OLive(o) /\ oIn[o] /\ ~OOver(o)
    /\ oIn' = [oIn EXCEPT ![o] = FALSE]
    /\ oCalls' = [oCalls EXCEPT ![o] = @ + 1]
    /\ UNCHANGED <<now, sOwner, storeStamp, oState, oNeeds, oCallAt, oStamped, frozen, w>> /\ UNCHANGED RVars


ORelease(o) ==
    /\ OLive(o)
    /\ (~oIn[o] /\ oCalls[o] = oNeeds[o]) \/ OOver(o)
    /\ sOwner' = "none"
    /\ oState' = [oState EXCEPT ![o] = "done"]
    /\ oIn' = [oIn EXCEPT ![o] = FALSE]
    /\ UNCHANGED <<now, storeStamp, oNeeds, oCalls, oCallAt, oStamped, frozen, w>> /\ UNCHANGED RVars


RNext(p) ==
    /\ phase' = p
    /\ rHold' = FALSE /\ rCalls' = 0 /\ rIn' = FALSE /\ rStamped' = FALSE
    /\ rWaitAt' = now
    /\ netAt' = IF p = "network" THEN now ELSE netAt
    /\ rStamp' = IF p \in {"network", "save"} THEN now ELSE rStamp

RAcquire ==
    /\ RLive /\ RWantsStore /\ sOwner = "none"
    /\ sOwner' = R /\ rHold' = TRUE
    /\ UNCHANGED <<now, storeStamp, phase, rCalls, rIn, rCallAt, rStamped, rWaitAt, netAt, rStamp, frozen, w>> /\ UNCHANGED OVars

RStampStore ==
    /\ RLive /\ rHold /\ ~rStamped /\ ~rIn /\ rCalls < RNeeds
    /\ rStamped' = TRUE /\ storeStamp' = now
    /\ UNCHANGED <<now, sOwner, phase, rHold, rCalls, rIn, rCallAt, rWaitAt, netAt, rStamp, frozen, w>> /\ UNCHANGED OVars

RStartCall ==
    /\ RLive /\ rHold /\ rStamped /\ ~rIn
    /\ rIn' = TRUE /\ rCallAt' = now /\ rStamped' = FALSE
    /\ UNCHANGED <<now, sOwner, storeStamp, phase, rHold, rCalls, rWaitAt, netAt, rStamp, frozen, w>> /\ UNCHANGED OVars

REndCall ==
    /\ RLive /\ rIn /\ ~ROver
    /\ rIn' = FALSE /\ rCalls' = rCalls + 1
    /\ UNCHANGED <<now, sOwner, storeStamp, phase, rHold, rCallAt, rStamped, rWaitAt, netAt, rStamp, frozen, w>> /\ UNCHANGED OVars


RRelease ==
    /\ RLive /\ rHold
    /\ (~rIn /\ rCalls = RNeeds) \/ ROver
    /\ sOwner' = "none"
    /\ RNext(IF phase = "lookup" THEN "network" ELSE "done")
    /\ UNCHANGED <<now, storeStamp, rCallAt, frozen, w>> /\ UNCHANGED OVars

RGiveUpStore ==
    /\ RLive /\ RWantsStore /\ sOwner # "none" /\ RStoreExpired
    /\ RNext(IF phase = "lookup" THEN "network" ELSE "done")
    /\ UNCHANGED <<now, sOwner, storeStamp, rCallAt, frozen, w>> /\ UNCHANGED OVars


RAnswer ==
    /\ RLive /\ phase = "network" /\ now - netAt < RefreshMax
    /\ RNext("save")
    /\ UNCHANGED <<now, sOwner, storeStamp, rCallAt, frozen, w>> /\ UNCHANGED OVars

RTimeout ==
    /\ RLive /\ phase = "network" /\ now - netAt >= RefreshMax
    /\ RNext("done")
    /\ UNCHANGED <<now, sOwner, storeStamp, rCallAt, frozen, w>> /\ UNCHANGED OVars

Freeze(p) ==
    /\ p \notin frozen
    /\ IF p = R THEN RLive ELSE OLive(p)
    /\ frozen' = frozen \cup {p}
    /\ UNCHANGED <<now, sOwner, storeStamp, w>> /\ UNCHANGED OVars /\ UNCHANGED RVars

WGet ==
    /\ w = "waiting" /\ phase = "done"
    /\ w' = "got"
    /\ UNCHANGED <<now, sOwner, storeStamp, frozen>> /\ UNCHANGED OVars /\ UNCHANGED RVars

WGoAhead ==
    /\ w = "waiting" /\ phase # "done" /\ GoAhead
    /\ w' = "went"
    /\ UNCHANGED <<now, sOwner, storeStamp, frozen>> /\ UNCHANGED OVars /\ UNCHANGED RVars



Due ==
    \/ \E o \in Others : OLive(o) /\ (~oIn[o] \/ OOver(o))
    \/ RLive /\ rHold /\ (~rIn \/ ROver)
    \/ RLive /\ RWantsStore /\ (sOwner = "none" \/ RStoreExpired)
    \/ RLive /\ phase = "network" /\ now - netAt >= RefreshMax
    \/ phase = "done"
    \/ GoAhead

Tick ==
    /\ w = "waiting" /\ ~Due
    /\ now' = now + 1
    /\ UNCHANGED <<sOwner, storeStamp, frozen, w>> /\ UNCHANGED OVars /\ UNCHANGED RVars

Next ==
    \/ \E o \in Others : OAcquire(o) \/ OStamp(o) \/ OStartCall(o) \/ OEndCall(o) \/ ORelease(o)
    \/ RAcquire \/ RStampStore \/ RStartCall \/ REndCall \/ RRelease \/ RGiveUpStore \/ RAnswer \/ RTimeout
    \/ \E p \in Others \cup {R} : Freeze(p)
    \/ WGet \/ WGoAhead \/ Tick

Spec == Init /\ [][Next]_vars

NoGoAheadPastLiveRefresher == w = "went" => R \in frozen
====
