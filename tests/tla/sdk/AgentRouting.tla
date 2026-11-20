----------------------------- MODULE AgentRouting -----------------------------
























EXTENDS Naturals, FiniteSets

CONSTANTS
    Names,
    Sessions,
    Procs,
    P2Lacks,
    MaxSends,
    ByName,
    CheckOwner

None == "none"
Hosts == [p \in Procs |-> IF p = "p2" THEN Names \ {P2Lacks} ELSE Names]

VARIABLES
    queue,
    owner,
    ran,
    missed,
    sends,
    act

vars == <<queue, owner, ran, missed, sends, act>>

Msg == [id: 0..MaxSends, s: Sessions, n: Names]

TypeOK ==
    /\ queue \subseteq Msg
    /\ owner \in [Sessions -> Names \cup {None}]
    /\ ran \subseteq (Sessions \X Names)
    /\ missed \subseteq Names
    /\ sends \in 0..MaxSends

Init ==
    /\ queue = {}
    /\ owner = [s \in Sessions |-> None]
    /\ ran = {}
    /\ missed = {}
    /\ sends = 0
    /\ act = [name |-> "Init"]


Stored(o, n) == IF o = None THEN n ELSE o


Send(n, s) ==
    /\ sends < MaxSends
    /\ queue' = queue \cup {[id |-> sends, s |-> s, n |-> n]}
    /\ sends' = sends + 1
    /\ owner' = [owner EXCEPT ![s] = Stored(@, n)]
    /\ act' = [name |-> "Send", n |-> n, s |-> s, id |-> sends]
    /\ UNCHANGED <<ran, missed>>



Deliver(p, m) ==
    /\ m \in queue
    /\ act' = [name |-> "Deliver", p |-> p, id |-> m.id]
    /\ IF ByName /\ m.n \notin Hosts[p]
       THEN /\ missed' = missed \cup {m.n}
            /\ UNCHANGED <<queue, owner, ran, sends>>
       ELSE \E a \in (IF ByName THEN {m.n} ELSE Hosts[p]):
                LET o == Stored(owner[m.s], m.n) IN
                /\ owner' = [owner EXCEPT ![m.s] = o]
                /\ IF CheckOwner /\ o # a
                   THEN /\ queue' = (queue \ {m}) \cup {[m EXCEPT !.n = o]}
                        /\ UNCHANGED ran
                   ELSE /\ queue' = queue \ {m}
                        /\ ran' = ran \cup {<<m.s, a>>}
                /\ UNCHANGED <<missed, sends>>

Next ==
    \/ \E n \in Names, s \in Sessions: Send(n, s)
    \/ \E p \in Procs, m \in queue: Deliver(p, m)

Spec == Init /\ [][Next]_vars



FairSpec == Spec /\ SF_vars(\E p \in Procs, m \in queue: m.n \in Hosts[p] /\ Deliver(p, m))

-----------------------------------------------------------------------------



RunsOnOwner == \A r \in ran: r[2] = owner[r[1]]


MissOnlyWhereLacking == \A n \in missed: \E p \in Procs: n \notin Hosts[p]


OwnerKept == [][\A s \in Sessions: owner[s] # None => owner'[s] = owner[s]]_vars



Drains == <>[](queue = {})
=============================================================================
