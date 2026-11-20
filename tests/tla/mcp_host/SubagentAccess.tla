---- MODULE SubagentAccess ----












EXTENDS Naturals, FiniteSets

CONSTANTS Servers, MaxRuns, MaxViews

Tools == Servers \X {1, 2}

VARIABLES run, usable, loaded, views

vars == <<run, usable, loaded, views>>

Views == [run : 1..MaxRuns, servers : SUBSET Servers, tools : SUBSET Tools]



Captured == [run |-> run, servers |-> usable, tools |-> {t \in Tools : t[1] \in loaded}]

ParentAllowed(t) == t[1] \in loaded

Allowed(v, t) ==
    /\ v.run = run
    /\ t[1] \in loaded
    /\ (t \in v.tools \/ t[1] \in v.servers)

Init ==
    /\ run = 1
    /\ usable \in SUBSET Servers
    /\ loaded = {}
    /\ views = {}

Load(s) ==
    /\ s \in usable \ loaded
    /\ loaded' = loaded \cup {s}
    /\ UNCHANGED <<run, usable, views>>

Create ==
    /\ Cardinality(views) < MaxViews
    /\ views' = views \cup {Captured}
    /\ UNCHANGED <<run, usable, loaded>>

Reload ==
    /\ run < MaxRuns
    /\ run' = run + 1
    /\ usable' \in SUBSET Servers
    /\ loaded' = {}
    /\ UNCHANGED views

Next == (\E s \in Servers : Load(s)) \/ Create \/ Reload

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ run \in 1..MaxRuns
    /\ usable \subseteq Servers
    /\ loaded \subseteq usable
    /\ views \subseteq Views


ChildWithinParent == \A v \in views, t \in Tools : Allowed(v, t) => ParentAllowed(t)



NotNarrower == \A v \in views : v.run = run => \A t \in Tools : ParentAllowed(t) => Allowed(v, t)


RunScoped == \A v \in views : v.run # run => \A t \in Tools : ~Allowed(v, t)
====
