------------------------------- MODULE McpCall -------------------------------


























EXTENDS Naturals, FiniteSets

CONSTANTS
    MaxInFlight,
    MaxIds

Owners == {"main", "child"}
Tokens == {"t1", "t2"}
Presented == Tokens \cup {"forged"}
Versions == {1, 2}
Ids == 0..(MaxIds - 1)
Stages == {"authorizing", "calling", "replying", "abandoned_auth", "abandoned_call"}
Outcomes == {"ok", "tool_error", "failed"}
ReplyOutcomes == Outcomes \cup {"denied"}
Reasons == {"closed", "unauthorized", "unsupported_version", "busy"}
Drops == {"stale", "result_dropped", "reply_lost"}

Entries == [id: Ids, owner: Owners, stage: Stages]
Registrations == [owner: Owners, token: Tokens]

Effects == [kind: {"refuse"}, reason: Reasons]
           \cup [kind: {"authorize", "call"}, id: Ids, owner: Owners]
           \cup [kind: {"withdraw", "cancel"}, id: Ids]
           \cup [kind: {"reply"}, id: Ids, outcome: ReplyOutcomes]
           \cup [kind: {"log"}, id: Ids, what: Drops]

Acts == [name: {"Init", "Stopped", "Crash"}]
        \cup [name: {"Started"}, token: Tokens]
        \cup [name: {"OwnerAdded"}, owner: Owners, token: Tokens]
        \cup [name: {"OwnerRemoved"}, owner: Owners]
        \cup [name: {"Request"}, token: Presented, version: Versions]
        \cup [name: {"Authorized"}, id: Ids, allow: BOOLEAN]
        \cup [name: {"CallFinished"}, id: Ids, outcome: Outcomes]
        \cup [name: {"ReplyDone"}, id: Ids, delivered: BOOLEAN]
        \cup [name: {"ClientGone"}, id: Ids]

VARIABLES open, registered, next, entries, out, act

vars == <<open, registered, next, entries, out, act>>

EntryIds == {e.id : e \in entries}
Entry(i) == CHOOSE e \in entries : e.id = i
Holds(i, stages) == i \in EntryIds /\ Entry(i).stage \in stages
InUse == {r.token : r \in registered}
RegOwners == {r.owner : r \in registered}


TokenOwner(t) == IF \E r \in registered : r.token = t
                 THEN (CHOOSE r \in registered : r.token = t).owner
                 ELSE "main"

SetStage(i, s) == {IF e.id = i THEN [e EXCEPT !.stage = s] ELSE e : e \in entries}
Remove(i) == {e \in entries : e.id # i}
Log(i, what) == [kind |-> "log", id |-> i, what |-> what]



Abandon(e) == CASE e.stage = "authorizing" -> [e EXCEPT !.stage = "abandoned_auth"]
                [] e.stage = "calling" -> [e EXCEPT !.stage = "abandoned_call"]
                [] OTHER -> e
LetGo(e) == CASE e.stage = "authorizing" -> {[kind |-> "withdraw", id |-> e.id]}
              [] e.stage = "calling" -> {[kind |-> "cancel", id |-> e.id]}
              [] OTHER -> {}
AbandonAll(S) ==
    /\ entries' = {IF e \in S THEN Abandon(e) ELSE e : e \in entries}
    /\ out' = UNION {LetGo(e) : e \in S}


FirstRefusal(t, v) ==
    CASE ~open -> "closed"
      [] t \notin InUse -> "unauthorized"
      [] v # 1 -> "unsupported_version"
      [] Cardinality(entries) >= MaxInFlight -> "busy"
      [] OTHER -> "none"

Init ==
    /\ open = FALSE
    /\ registered = {}
    /\ next = 0
    /\ entries = {}
    /\ out = {}
    /\ act = [name |-> "Init"]



Started(t) ==
    /\ act' = [name |-> "Started", token |-> t]
    /\ out' = {}
    /\ IF open
       THEN UNCHANGED <<open, registered>>
       ELSE /\ open' = TRUE
            /\ registered' = {[owner |-> "main", token |-> t]}
    /\ UNCHANGED <<next, entries>>



Stopped ==
    /\ act' = [name |-> "Stopped"]
    /\ IF open
       THEN /\ open' = FALSE
            /\ registered' = {}
            /\ AbandonAll(entries)
       ELSE /\ out' = {}
            /\ UNCHANGED <<open, registered, entries>>
    /\ UNCHANGED next


OwnerAdded(o, t) ==
    /\ act' = [name |-> "OwnerAdded", owner |-> o, token |-> t]
    /\ out' = {}
    /\ IF open /\ o \notin RegOwners /\ t \notin InUse
       THEN registered' = registered \cup {[owner |-> o, token |-> t]}
       ELSE UNCHANGED registered
    /\ UNCHANGED <<open, next, entries>>



OwnerRemoved(o) ==
    /\ act' = [name |-> "OwnerRemoved", owner |-> o]
    /\ IF o # "main" /\ o \in RegOwners
       THEN /\ registered' = {r \in registered : r.owner # o}
            /\ AbandonAll({e \in entries : e.owner = o})
       ELSE /\ out' = {}
            /\ UNCHANGED <<registered, entries>>
    /\ UNCHANGED <<open, next>>


Request(t, v) ==
    /\ next < MaxIds
    /\ act' = [name |-> "Request", token |-> t, version |-> v]
    /\ LET reason == FirstRefusal(t, v) IN
       IF reason # "none"
       THEN /\ out' = {[kind |-> "refuse", reason |-> reason]}
            /\ UNCHANGED <<open, registered, next, entries>>
       ELSE LET e == [id |-> next, owner |-> TokenOwner(t), stage |-> "authorizing"] IN
            /\ entries' = entries \cup {e}
            /\ next' = next + 1
            /\ out' = {[kind |-> "authorize", id |-> e.id, owner |-> e.owner]}
            /\ UNCHANGED <<open, registered>>


Authorized(i, allow) ==
    /\ act' = [name |-> "Authorized", id |-> i, allow |-> allow]
    /\ CASE Holds(i, {"authorizing"}) ->
              IF allow
              THEN /\ entries' = SetStage(i, "calling")
                   /\ out' = {[kind |-> "call", id |-> i, owner |-> Entry(i).owner]}
              ELSE /\ entries' = SetStage(i, "replying")
                   /\ out' = {[kind |-> "reply", id |-> i, outcome |-> "denied"]}
         [] Holds(i, {"abandoned_auth"}) ->
              /\ entries' = Remove(i)
              /\ out' = {}
         [] OTHER ->
              /\ entries' = entries
              /\ out' = {Log(i, "stale")}
    /\ UNCHANGED <<open, registered, next>>


CallFinished(i, o) ==
    /\ act' = [name |-> "CallFinished", id |-> i, outcome |-> o]
    /\ CASE Holds(i, {"calling"}) ->
              /\ entries' = SetStage(i, "replying")
              /\ out' = {[kind |-> "reply", id |-> i, outcome |-> o]}
         [] Holds(i, {"abandoned_call"}) ->
              /\ entries' = Remove(i)
              /\ out' = IF o = "failed" THEN {} ELSE {Log(i, "result_dropped")}
         [] OTHER ->
              /\ entries' = entries
              /\ out' = {Log(i, "stale")}
    /\ UNCHANGED <<open, registered, next>>


ReplyDone(i, delivered) ==
    /\ act' = [name |-> "ReplyDone", id |-> i, delivered |-> delivered]
    /\ IF Holds(i, {"replying"})
       THEN /\ entries' = Remove(i)
            /\ out' = IF delivered THEN {} ELSE {Log(i, "reply_lost")}
       ELSE /\ entries' = entries
            /\ out' = {Log(i, "stale")}
    /\ UNCHANGED <<open, registered, next>>


ClientGone(i) ==
    /\ act' = [name |-> "ClientGone", id |-> i]
    /\ IF Holds(i, {"authorizing", "calling"})
       THEN /\ entries' = {IF e.id = i THEN Abandon(e) ELSE e : e \in entries}
            /\ out' = LetGo(Entry(i))
       ELSE /\ entries' = entries
            /\ out' = {}
    /\ UNCHANGED <<open, registered, next>>



Crash ==
    /\ act' = [name |-> "Crash"]
    /\ open' = FALSE
    /\ registered' = {}
    /\ next' = 0
    /\ entries' = {}
    /\ out' = {}

Next ==
    \/ \E t \in Tokens : Started(t)
    \/ Stopped
    \/ \E o \in Owners, t \in Tokens : OwnerAdded(o, t)
    \/ \E o \in Owners : OwnerRemoved(o)
    \/ \E t \in Presented, v \in Versions : Request(t, v)
    \/ \E i \in Ids, a \in BOOLEAN : Authorized(i, a)
    \/ \E i \in Ids, o \in Outcomes : CallFinished(i, o)
    \/ \E i \in Ids, d \in BOOLEAN : ReplyDone(i, d)
    \/ \E i \in Ids : ClientGone(i)
    \/ Crash




Answer(i) == Holds(i, {"authorizing", "abandoned_auth"}) /\ \E a \in BOOLEAN : Authorized(i, a)
Finish(i) == Holds(i, {"calling", "abandoned_call"}) /\ \E o \in Outcomes : CallFinished(i, o)
Deliver(i) == Holds(i, {"replying"}) /\ \E d \in BOOLEAN : ReplyDone(i, d)

Spec == Init /\ [][Next]_vars /\ \A i \in Ids : WF_vars(Answer(i)) /\ WF_vars(Finish(i)) /\ WF_vars(Deliver(i))

-----------------------------------------------------------------------------




Live == {"authorizing", "calling"}
Advances == {<<s, s>> : s \in Stages}
            \cup {<<"authorizing", "calling">>, <<"authorizing", "replying">>,
                  <<"authorizing", "abandoned_auth">>, <<"calling", "replying">>,
                  <<"calling", "abandoned_call">>}

Ends == {<<"Authorized", "abandoned_auth">>, <<"CallFinished", "abandoned_call">>, <<"ReplyDone", "replying">>}

Expected == {<<"Authorized", "authorizing">>, <<"Authorized", "abandoned_auth">>,
             <<"CallFinished", "calling">>, <<"CallFinished", "abandoned_call">>,
             <<"ReplyDone", "replying">>, <<"ClientGone", "authorizing">>, <<"ClientGone", "calling">>}
IdEvents == {"Authorized", "CallFinished", "ReplyDone", "ClientGone"}

TypeOK ==
    /\ open \in BOOLEAN
    /\ registered \subseteq Registrations
    /\ next \in 0..MaxIds
    /\ entries \subseteq Entries
    /\ out \subseteq Effects
    /\ act \in Acts



Bounded ==
    /\ Cardinality(entries) <= MaxInFlight
    /\ Cardinality(out) <= MaxInFlight
    /\ Cardinality(out) > 1 => act.name \in {"Stopped", "OwnerRemoved"}
    /\ \A i \in EntryIds : Cardinality({e \in entries : e.id = i}) = 1
    /\ \A o \in Owners : Cardinality({r \in registered : r.owner = o}) <= 1
    /\ \A t \in Tokens : Cardinality({r \in registered : r.token = t}) <= 1


IdsBelowNext == \A i \in EntryIds : i < next


EffectsCarryEntryOwner ==
    \A e \in out : e.kind \in {"authorize", "call"} =>
        \E x \in entries : x.id = e.id /\ x.owner = e.owner


LiveWorkHasOwner == \A x \in entries : x.stage \in Live => x.owner \in {r.owner : r \in registered}


ClosedIsQuiet == ~open => (registered = {} /\ \A e \in out : e.kind \notin {"authorize", "call"})


CrashResets == act.name \in {"Init", "Crash"} => (~open /\ registered = {} /\ next = 0 /\ entries = {} /\ out = {})




AdmitOnlyValid ==
    [][\A i \in {e.id : e \in entries'} \ EntryIds :
          /\ act'.name = "Request"
          /\ open
          /\ \E r \in registered : r.token = act'.token
          /\ act'.version = 1
          /\ Cardinality(entries) < MaxInFlight
          /\ \E e \in entries' : /\ e.id = i
                                 /\ e.stage = "authorizing"
                                 /\ \E r \in registered : r.token = act'.token /\ r.owner = e.owner]_vars




RefusalsAreQuiet ==
    [][(\E e \in out' : e.kind = "refuse") =>
          /\ act'.name = "Request"
          /\ Cardinality(out') = 1
          /\ UNCHANGED <<open, registered, next, entries>>
          /\ LET reason == (CHOOSE e \in out' : TRUE).reason
                 known == \E r \in registered : r.token = act'.token
             IN /\ (reason = "closed") <=> ~open
                /\ (reason = "unauthorized") <=> (open /\ ~known)
                /\ (reason = "unsupported_version") => (open /\ known /\ act'.version # 1)
                /\ (reason = "busy") => (open /\ known /\ act'.version = 1 /\ Cardinality(entries) >= MaxInFlight)]_vars



FreshIds ==
    [][/\ \A e \in out' : e.kind = "authorize" => (e.id = next /\ next' = next + 1 /\ e.id \notin EntryIds)
       /\ next' # next => (act'.name = "Crash" \/ \E e \in out' : e.kind = "authorize")]_vars




CallOnlyFromAuthorizing ==
    [][\A e \in out' : e.kind = "call" =>
          /\ act'.name = "Authorized" /\ act'.id = e.id /\ act'.allow
          /\ \E x \in entries : x.id = e.id /\ x.stage = "authorizing"
          /\ \E y \in entries' : y.id = e.id /\ y.stage = "calling"]_vars



StagesOnlyAdvance ==
    [][/\ \A x \in entries, y \in entries' : x.id = y.id => (<<x.stage, y.stage>> \in Advances /\ x.owner = y.owner)
       /\ \A x \in entries : x.id \notin {e.id : e \in entries'} =>
              (act'.name = "Crash" \/ (act'.name \in IdEvents /\ act'.id = x.id /\ <<act'.name, x.stage>> \in Ends))]_vars



OneReplyPerRequest ==
    [][\A e \in out' : e.kind = "reply" =>
          /\ \E x \in entries : x.id = e.id /\ x.stage \in Live
          /\ \E y \in entries' : y.id = e.id /\ y.stage = "replying"]_vars


ReplyMatchesOutcome ==
    [][\A e \in out' : e.kind = "reply" =>
          \/ act'.name = "CallFinished" /\ act'.id = e.id /\ e.outcome = act'.outcome
          \/ act'.name = "Authorized" /\ act'.id = e.id /\ ~act'.allow /\ e.outcome = "denied"]_vars




StaleIsQuiet ==
    [][(act'.name \in IdEvents /\ ~\E x \in entries : x.id = act'.id /\ <<act'.name, x.stage>> \in Expected) =>
          /\ UNCHANGED <<open, registered, next, entries>>
          /\ out' = IF act'.name = "ClientGone" THEN {} ELSE {[kind |-> "log", id |-> act'.id, what |-> "stale"]}]_vars



DroppedStateIsLogged ==
    [][/\ (act'.name = "CallFinished" /\ act'.outcome # "failed" /\ \E x \in entries : x.id = act'.id /\ x.stage = "abandoned_call")
             => [kind |-> "log", id |-> act'.id, what |-> "result_dropped"] \in out'
       /\ (act'.name = "ReplyDone" /\ ~act'.delivered /\ \E x \in entries : x.id = act'.id /\ x.stage = "replying")
             => [kind |-> "log", id |-> act'.id, what |-> "reply_lost"] \in out']_vars



Drained == \A i \in Ids : (i \in EntryIds) ~> (i \notin EntryIds)
=============================================================================
