---- MODULE HostLifecycle ----















































EXTENDS Naturals, FiniteSets

CONSTANTS
    Servers,
    Project,
    Reachable,
    NeedsAuth,
    MaxReloads,
    MaxLeases

ASSUME Project \subseteq Servers /\ Reachable \subseteq Servers /\ NeedsAuth \subseteq Reachable
ASSUME MaxReloads \in Nat /\ MaxLeases \in Nat


Hosts == {1}
States == {"absent", "waiting", "rejected", "idle", "starting", "ready", "needs_login", "failed"}
Decisions == {"ok", "pending", "approved", "rejected", "removed"}
Changes == {"approved", "rejected", "removed", "ok"}
Lines == [k : {"none", "attn", "many"}, who : Servers \cup {""}, why : {"", "waiting", "login", "failed"}, r : 0..10, e : 0..10]
NoLine == [k |-> "none", who |-> "", why |-> "", r |-> 0, e |-> 0]

VARIABLES
    decision,
    loaded,
    cur,
    alive,
    retired,
    leases,
    st,
    procs,
    stopping,
    termed,
    framed,
    quit,
    shown,
    refreshed,
    heldAt,
    reloads

vars == <<decision, cur, alive, retired, leases, st, procs, stopping, termed, framed, quit, shown, refreshed, heldAt, reloads, loaded>>

D0 == [s \in Servers |-> IF s \in Project THEN "pending" ELSE "ok"]


Initial(d, s) == CASE d[s] = "removed" -> "absent"
                   [] d[s] = "pending" -> "waiting"
                   [] d[s] = "rejected" -> "rejected"
                   [] OTHER -> "idle"
Held(d) == {s \in Servers : Initial(d, s) \in {"absent", "waiting", "rejected"}}

Started(x) == IF x = "idle" THEN "starting" ELSE x



Needy(h) == {s \in Servers : st[h][s] \in {"waiting", "needs_login", "failed"}}
Why(x) == CASE x = "waiting" -> "waiting" [] x = "needs_login" -> "login" [] OTHER -> "failed"
Line(h) ==
    IF Cardinality(Needy(h)) = 1
    THEN LET s == CHOOSE x \in Needy(h) : TRUE
         IN [k |-> "attn", who |-> s, why |-> Why(st[h][s]), r |-> 0, e |-> 0]
    ELSE IF Cardinality(Needy(h)) > 1
    THEN [k |-> "many", who |-> "", why |-> "", r |-> Cardinality(Needy(h)), e |-> 0]
    ELSE NoLine

Of(h) == {p \in procs : p[1] = h}
Live == procs \cup stopping

TypeOK ==
    /\ decision \in [Servers -> Decisions]
    /\ loaded \in [Servers -> Decisions]
    /\ cur \in Hosts
    /\ alive \in [Hosts -> BOOLEAN]
    /\ retired \in [Hosts -> BOOLEAN]
    /\ leases \in [Hosts -> 0..MaxLeases]
    /\ st \in [Hosts -> [Servers -> States]]
    /\ procs \subseteq Hosts \X Servers
    /\ stopping \subseteq Hosts \X Servers
    /\ termed \subseteq Hosts \X Servers
    /\ framed \in BOOLEAN /\ quit \in BOOLEAN /\ refreshed \in BOOLEAN
    /\ shown \in Lines
    /\ heldAt \in [Hosts -> SUBSET Servers]
    /\ reloads \in 0..MaxReloads

Init ==
    /\ decision = D0
    /\ loaded = D0
    /\ cur = 1
    /\ alive = [h \in Hosts |-> h = 1]
    /\ retired = [h \in Hosts |-> FALSE]
    /\ leases = [h \in Hosts |-> 0]
    /\ st = [h \in Hosts |-> [s \in Servers |-> IF h = 1 THEN Initial(D0, s) ELSE "absent"]]
    /\ procs = {} /\ stopping = {} /\ termed = {}
    /\ framed = FALSE /\ quit = FALSE
    /\ shown = NoLine /\ refreshed = FALSE
    /\ heldAt = [h \in Hosts |-> IF h = 1 THEN Held(D0) ELSE {}]
    /\ reloads = 0


FirstFrame ==
    /\ ~framed /\ ~quit
    /\ framed' = TRUE
    /\ st' = [st EXCEPT ![cur] = [s \in Servers |-> Started(st[cur][s])]]
    /\ refreshed' = FALSE
    /\ UNCHANGED <<decision, cur, alive, retired, leases, procs, stopping, termed, quit, shown, heldAt, reloads, loaded>>


Need(s) ==
    /\ ~quit /\ st[cur][s] = "idle"
    /\ st' = [st EXCEPT ![cur][s] = "starting"]
    /\ refreshed' = FALSE
    /\ UNCHANGED <<decision, cur, alive, retired, leases, procs, stopping, termed, framed, quit, shown, heldAt, reloads, loaded>>




Spawn(h, s) ==
    /\ ~quit /\ alive[h] /\ st[h][s] = "starting" /\ <<h, s>> \notin procs
    /\ \A p \in Live : p[2] # s
    /\ procs' = procs \cup {<<h, s>>}
    /\ refreshed' = FALSE
    /\ UNCHANGED <<decision, cur, alive, retired, leases, st, stopping, termed, framed, quit, shown, heldAt, reloads, loaded>>


Answer(h, s) ==
    /\ ~quit /\ alive[h] /\ st[h][s] = "starting" /\ <<h, s>> \in procs /\ s \in Reachable
    /\ st' = [st EXCEPT ![h][s] = IF s \in NeedsAuth THEN "needs_login" ELSE "ready"]
    /\ refreshed' = FALSE
    /\ UNCHANGED <<decision, cur, alive, retired, leases, procs, stopping, termed, framed, quit, shown, heldAt, reloads, loaded>>


GiveUp(h, s) ==
    /\ ~quit /\ alive[h] /\ st[h][s] = "starting" /\ s \notin Reachable
    /\ st' = [st EXCEPT ![h][s] = "failed"]
    /\ procs' = procs \ {<<h, s>>}
    /\ refreshed' = FALSE
    /\ UNCHANGED <<decision, cur, alive, retired, leases, stopping, termed, framed, quit, shown, heldAt, reloads, loaded>>


Lease ==
    /\ ~quit /\ leases[cur] < MaxLeases
    /\ leases' = [leases EXCEPT ![cur] = @ + 1]
    /\ refreshed' = FALSE
    /\ UNCHANGED <<decision, cur, alive, retired, st, procs, stopping, termed, framed, quit, shown, heldAt, reloads, loaded>>




Release(h) ==
    /\ ~quit /\ leases[h] > 0
    /\ leases' = [leases EXCEPT ![h] = @ - 1]
    /\ IF retired[h] /\ leases[h] = 1
       THEN /\ alive' = [alive EXCEPT ![h] = FALSE]
            /\ procs' = procs \ Of(h)
            /\ stopping' = stopping \cup Of(h)
       ELSE UNCHANGED <<alive, procs, stopping>>
    /\ refreshed' = FALSE
    /\ UNCHANGED <<decision, cur, retired, st, termed, framed, quit, shown, heldAt, reloads, loaded>>




Change(s, d) ==
    \/ d = "approved" /\ decision[s] = "pending"
    \/ d = "rejected" /\ decision[s] = "pending"
    \/ d = "removed" /\ decision[s] # "removed"
    \/ d = "ok" /\ decision[s] = "removed"

Edit(s, d) ==
    /\ ~quit /\ reloads < MaxReloads /\ Change(s, d)
    /\ reloads' = reloads + 1
    /\ decision' = [decision EXCEPT ![s] = d]
    /\ refreshed' = FALSE
    /\ UNCHANGED <<cur, alive, retired, leases, st, procs, stopping, termed, framed, quit, shown, heldAt, loaded>>


Stale == {s \in Servers : loaded[s] # decision[s]}







Reload ==
    /\ ~quit /\ Stale # {}
    /\ LET gone == {p \in procs : p[1] = cur /\ p[2] \in Stale}
       IN /\ loaded' = decision
          /\ st' = [st EXCEPT ![cur] = [s \in Servers |-> IF s \in Stale THEN Started(Initial(decision, s)) ELSE st[cur][s]]]
          /\ heldAt' = [heldAt EXCEPT ![cur] = Held(decision)]
          /\ procs' = procs \ gone
          /\ stopping' = stopping \cup gone
    /\ refreshed' = FALSE
    /\ UNCHANGED <<decision, cur, alive, retired, leases, termed, framed, quit, shown, reloads>>


Exit(h, s) ==
    /\ <<h, s>> \in stopping
    /\ stopping' = stopping \ {<<h, s>>}
    /\ refreshed' = FALSE
    /\ UNCHANGED <<decision, cur, alive, retired, leases, st, procs, termed, framed, quit, shown, heldAt, reloads, loaded>>



Quit ==
    /\ ~quit
    /\ quit' = TRUE
    /\ termed' = termed \cup procs \cup stopping
    /\ alive' = [h \in Hosts |-> FALSE]
    /\ refreshed' = FALSE
    /\ UNCHANGED <<decision, cur, retired, leases, st, procs, stopping, framed, shown, heldAt, reloads, loaded>>


TermExit(h, s) ==
    /\ <<h, s>> \in termed /\ <<h, s>> \in Live
    /\ procs' = procs \ {<<h, s>>}
    /\ stopping' = stopping \ {<<h, s>>}
    /\ refreshed' = FALSE
    /\ UNCHANGED <<decision, cur, alive, retired, leases, st, termed, framed, quit, shown, heldAt, reloads, loaded>>


RefreshStatus ==
    /\ ~quit
    /\ shown' = Line(cur)
    /\ refreshed' = TRUE
    /\ UNCHANGED <<decision, cur, alive, retired, leases, st, procs, stopping, termed, framed, quit, heldAt, reloads, loaded>>

Next ==
    \/ FirstFrame
    \/ \E s \in Servers : Need(s)
    \/ \E h \in Hosts, s \in Servers : Spawn(h, s) \/ Answer(h, s) \/ GiveUp(h, s) \/ Exit(h, s) \/ TermExit(h, s)
    \/ Lease
    \/ \E h \in Hosts : Release(h)
    \/ \E s \in Servers, d \in Changes : Edit(s, d)
    \/ Reload
    \/ Quit
    \/ RefreshStatus

    \/ (quit /\ Live = {} /\ UNCHANGED vars)

Fairness ==
    /\ WF_vars(FirstFrame)
    /\ \A h \in Hosts, s \in Servers :
          WF_vars(Spawn(h, s)) /\ WF_vars(Answer(h, s)) /\ WF_vars(GiveUp(h, s)) /\ WF_vars(Exit(h, s)) /\ WF_vars(TermExit(h, s))
    /\ \A h \in Hosts : WF_vars(Release(h))


    /\ WF_vars(Reload)

Spec == Init /\ [][Next]_vars /\ Fairness





HeldNeverSpawned == \A p \in procs : p[2] \notin heldAt[p[1]]



StartedAfterFirstFrame == (framed /\ ~quit) => \A s \in Servers : st[cur][s] # "idle"


RefreshedLineAgrees == refreshed => shown = Line(cur)


QuitSignalsEveryServer == quit => Live \subseteq termed


RemovedNotRunning == \A s \in Servers : loaded[s] = "removed" => <<cur, s>> \notin procs


AtMostOneOwner == Cardinality({h \in Hosts : alive[h]}) <= 1



OneProcessPerServer ==
    /\ procs \cap stopping = {}
    /\ \A s \in Servers : Cardinality({h \in Hosts : <<h, s>> \in Live}) <= 1







KeptServersKeepRunning ==
    [][\A p \in procs : p \notin procs' =>
         loaded'[p[2]] # loaded[p[2]] \/ quit \/ st[p[1]][p[2]] = "starting"]_vars





ApprovedServersSettle == \A s \in Servers :
    <>[](quit \/ decision[s] \in {"pending", "rejected", "removed"}
         \/ (s \in Reachable \ NeedsAuth /\ st[cur][s] = "ready")
         \/ (s \in NeedsAuth /\ st[cur][s] = "needs_login")
         \/ (s \notin Reachable /\ st[cur][s] = "failed"))


EveryStopEnds == []<>(stopping = {} /\ (quit => procs = {}))
====
