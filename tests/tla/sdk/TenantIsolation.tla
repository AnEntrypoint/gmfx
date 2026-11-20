--------------------------- MODULE TenantIsolation ---------------------------





































EXTENDS Naturals, FiniteSets

CONSTANTS
    Topology,
    MaxPrompts,
    MaxForges,
    LogFirst,
    RouteByStore,
    OneDefinition,
    Admission

None == "none"
Forger == "forger"






Tenants ==
    CASE Topology = "four" -> {"acme", "evil", "bob", "carl"}
      [] Topology = "shared" -> {"acme", "evil"}
      [] Topology = "split" -> {"acme", "carl"}
NameOf == [t \in Tenants |-> IF t = "bob" THEN "billing" ELSE "support"]
KeyOf == [t \in Tenants |-> IF t = "carl" THEN "k2" ELSE "k1"]
StoreOf == [t \in Tenants |->
    CASE t = "acme" -> "A"
      [] t = "evil" -> IF Topology = "shared" THEN "A" ELSE "B"
      [] t = "bob" -> "A"
      [] t = "carl" -> "C"]

Names == {NameOf[t] : t \in Tenants}
Keys == {KeyOf[t] : t \in Tenants}
Stores == {StoreOf[t] : t \in Tenants}

Ids == 0..MaxPrompts
Contexts == Tenants \cup {Forger, None}
Sizes == {"ok", "big", None}

Msg == [id: Ids, s: Tenants, n: Names, key: Keys, ctx: Contexts, size: Sizes]
Entry == [id: Ids, s: Tenants, n: Names, ctx: Contexts, size: Sizes]
Turn == [id: Ids, def: Tenants, store: Stores, ctx: Contexts]

VARIABLES
    agents,
    refused,
    log,
    owner,
    done,
    queue,
    ran,
    sent,
    forges,
    act

vars == <<agents, refused, log, owner, done, queue, ran, sent, forges, act>>

TypeOK ==
    /\ agents \subseteq Tenants
    /\ refused \subseteq Tenants
    /\ log \in [Stores -> SUBSET Entry]
    /\ owner \in [Stores -> [Tenants -> Names \cup {None}]]
    /\ done \in [Stores -> SUBSET Ids]
    /\ queue \subseteq Msg
    /\ ran \subseteq Turn
    /\ sent \subseteq [id: Ids, t: Tenants]
    /\ forges \in 0..MaxForges

Init ==
    /\ agents = {}
    /\ refused = {}
    /\ log = [st \in Stores |-> {}]
    /\ owner = [st \in Stores |-> [s \in Tenants |-> None]]
    /\ done = [st \in Stores |-> {}]
    /\ queue = {}
    /\ ran = {}
    /\ sent = {}
    /\ forges = 0
    /\ act = [name |-> "Init"]


Ref(m) == IF LogFirst THEN [m EXCEPT !.ctx = None, !.size = None] ELSE m


Register(t) ==
    /\ t \notin agents \cup refused
    /\ IF OneDefinition /\ \E u \in agents: NameOf[u] = NameOf[t] /\ KeyOf[u] = KeyOf[t]
       THEN /\ refused' = refused \cup {t}
            /\ UNCHANGED agents
       ELSE /\ agents' = agents \cup {t}
            /\ UNCHANGED refused
    /\ act' = [name |-> "Register", t |-> t]
    /\ UNCHANGED <<log, owner, done, queue, ran, sent, forges>>


Send(t, size) ==
    LET id == Cardinality(sent) + 1
        st == StoreOf[t]
        m == [id |-> id, s |-> t, n |-> NameOf[t], key |-> KeyOf[t], ctx |-> t, size |-> size]
    IN
    /\ t \in agents
    /\ Cardinality(sent) < MaxPrompts
    /\ sent' = sent \cup {[id |-> id, t |-> t]}
    /\ queue' = queue \cup {Ref(m)}
    /\ IF LogFirst
       THEN /\ log' = [log EXCEPT ![st] = @ \cup {[id |-> id, s |-> t, n |-> NameOf[t], ctx |-> t, size |-> size]}]
            /\ owner' = [owner EXCEPT ![st][t] = IF @ = None THEN NameOf[t] ELSE @]
       ELSE UNCHANGED <<log, owner>>
    /\ UNCHANGED <<agents, refused, done, ran, forges>>

Prompt(t) ==
    /\ Send(t, "ok")
    /\ act' = [name |-> "Prompt", t |-> t, id |-> Cardinality(sent) + 1]


Oversize(t, k) ==
    /\ t \in agents
    /\ IF Admission
       THEN UNCHANGED <<agents, refused, log, owner, done, queue, ran, sent, forges>>
       ELSE Send(t, "big")
    /\ act' = [name |-> "Oversize", t |-> t, k |-> k]


Candidates(m) == {a \in agents: NameOf[a] = m.n /\ (RouteByStore => KeyOf[a] = m.key)}


Take(m, a, rest) ==
    LET st == StoreOf[a]
        held == {x \in log[st]: x.id = m.id /\ x.s = m.s}
        own == IF owner[st][m.s] = None THEN m.n ELSE owner[st][m.s]
        body == [id |-> m.id, s |-> m.s, n |-> m.n, ctx |-> m.ctx, size |-> m.size]
        logged == IF held = {} THEN log[st] \cup {body} ELSE log[st]
        pend == {x \in logged: x.s = m.s /\ x.id \notin done[st]}
    IN
    IF LogFirst /\ held = {}
    THEN
         /\ queue' = rest
         /\ UNCHANGED <<log, owner, done, ran>>
    ELSE IF own # NameOf[a]
    THEN
         /\ queue' = rest \cup {Ref([m EXCEPT !.n = own])}
         /\ UNCHANGED <<log, owner, done, ran>>
    ELSE /\ log' = [log EXCEPT ![st] = logged]
         /\ owner' = [owner EXCEPT ![st][m.s] = own]
         /\ ran' = ran \cup {[id |-> x.id, def |-> a, store |-> st, ctx |-> x.ctx] : x \in pend}
         /\ done' = [done EXCEPT ![st] = @ \cup {x.id : x \in pend}]
         /\ queue' = rest



Handle(m, rest, missed) ==
    IF Candidates(m) = {}
    THEN /\ queue' = missed
         /\ UNCHANGED <<log, owner, done, ran>>
    ELSE \E a \in Candidates(m): Take(m, a, rest)


Deliver(m) ==
    /\ m \in queue
    /\ Handle(m, queue \ {m}, queue)
    /\ act' = [name |-> "Deliver", id |-> m.id, s |-> m.s, n |-> m.n, key |-> m.key]
    /\ UNCHANGED <<agents, refused, sent, forges>>


Forge(id, s, n, key) ==
    /\ forges < MaxForges
    /\ id \in {0} \cup {x.id : x \in sent}
    /\ Handle([id |-> id, s |-> s, n |-> n, key |-> key, ctx |-> Forger, size |-> "ok"], queue, queue)
    /\ forges' = forges + 1
    /\ act' = [name |-> "Forge", id |-> id, s |-> s, n |-> n, key |-> key]
    /\ UNCHANGED <<agents, refused, sent>>

Next ==
    \/ \E t \in Tenants: Register(t)
    \/ \E t \in Tenants: Prompt(t)
    \/ \E t \in Tenants, k \in {"prompt", "steer"}: Oversize(t, k)
    \/ \E m \in queue: Deliver(m)
    \/ \E id \in Ids, s \in Tenants, n \in Names, key \in Keys: Forge(id, s, n, key)

Spec == Init /\ [][Next]_vars


FairSpec == Spec /\ WF_vars(\E m \in queue: Candidates(m) # {} /\ Deliver(m))

-----------------------------------------------------------------------------


Sender(r) == {x \in sent: x.id = r.id}


OnlySentRuns == \A r \in ran: Sender(r) # {}



RunsOnSenderAgent == \A r \in ran: \A x \in Sender(r): r.def = x.t
RunsInSenderStore == \A r \in ran: \A x \in Sender(r): r.store = StoreOf[x.t]
RunsWithSenderContext == \A r \in ran: \A x \in Sender(r): r.ctx = x.t


StoredWithinLimit == \A st \in Stores: \A e \in log[st]: e.size # "big"


SentRuns == \A i \in 1..MaxPrompts: []((\E x \in sent: x.id = i) => <>(\E r \in ran: r.id = i))
=============================================================================
